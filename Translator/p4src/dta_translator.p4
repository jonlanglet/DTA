/*
 * 
 * P4_16 for Tofino ASIC
 * Written Aug- 2021 for Direct Telemetry Access
 * Translator pipeline
 * 
 */
#include <core.p4>
#include <tna.p4>

#define ETHERTYPE_IPV4 0x0800
#define ETHERTYPE_PITCHER 0x1337

#define IPv4_PROTO_UDP 0x11 //IPv4 proto number for UDP

#define CHECKSUM_CACHE_REGISTER_SIZE 65536 //Make sure this fits into telemetry_checksum_cache_index_t
//#define NUM_COLLECTORS 256 //Ensure this fits in server_id_t

#define DTA_PORT_NUMBER 40040
#define DTA_ACK_PORT_NUMBER 40044

#define DTA_OPCODE_KEYWRITE 0x01
#define DTA_OPCODE_APPEND 0x02
#define DTA_OPCODE_KEYINCREMENT 0x03
#define DTA_OPCODE_POSTCARDER 0x04


#define ROCEV2_UDP_PORT 4791 //4791 is the correct RoCEv2 port number
//#define ROCEV2_UDP_PORT 5000 //Used to bypass RDMA processing (for debugging)

#define POSTCARDER_CACHE_SIZE 32768


#ifndef MAX_SUPPORTED_QPS
	#define MAX_SUPPORTED_QPS 256 //Maximum number of supported QPs. Specifies table and register sizes
	//#define MAX_SUPPORTED_QPS 65536 //Used when benchmarking tons of QPs
#endif

typedef bit<32> ipv4_address_t;

typedef bit<32> debug_t;
typedef bit<16> random_t;
typedef bit<16> telemetry_checksum_t;
typedef bit<16> telemetry_checksum_cache_index_t; //Make sure this is log(CHECKSUM_CACHE_REGISTER_SIZE)
typedef bit<8> redundancy_entry_num_t;
typedef bit<32> telemetry_key_t;

typedef bit<8> hop_num_t;
typedef bit<32> postcarder_data_t;
typedef bit<15> postcarder_cache_index_t; //can fit 32 768

//To update size of keywrite data:
//INFO: This has to be a power of 2 to allow slot->addr conversion
//1. Set this value (must be equal to power of 2, including checksum)
//2. Update the keywrite_data_h to reflect data size changes
//3. Update keywrite_slot_size_B in switch_cpu.py
//4. Update the traffic generator to send correct packets
//5. Update the collector struct to handle this size (struct keywriteEntry)
#define KEYWRITE_RDMA_PAYLOAD_SIZE 8 //Size of keywrite payload (data+checksum) (bytes). 
//#define KEYWRITE_RDMA_PAYLOAD_SIZE 16 //12B data (3x4B)
//#define KEYWRITE_RDMA_PAYLOAD_SIZE 32 //28B data (7x4B)

typedef bit<32> telemetry_key_checksum_t;
typedef bit<32> keyval_data_t; //data for keywrite
typedef bit<64> keyincrement_counter_t; //Counter in keyincrement

//#define DO_NACK_TRACKING
#ifndef NUM_TRACKED_NACKS
	#define NUM_TRACKED_NACKS 65536
#endif

//To change batch size: 
//INFO: ensure that the number of batched elements is a power of 2
//1. Update values here
//2. update in append rdma payload header (automatic)
//3. modify register handling in batch control block (automatic)
#ifndef APPEND_BATCH_SIZE
	//#define APPEND_BATCH_SIZE 16 //This has to be NUM_APPEND_ENTRIES_IN_REGISTERS+1. Also make sure it's a power of 2, otherwise does not handle ring buffer rollover
	//#define NUM_APPEND_ENTRIES_IN_REGISTERS 15 //This should be batchsize-1. This is how many we use registers to store in-pipeline
	//#define APPEND_RDMA_PAYLOAD_SIZE 64 //Size of append payload (data) (bytes), multiplied by number of batch elements (8) 4*8=32 (16->64B)

	#define APPEND_BATCH_SIZE 4
	#define NUM_APPEND_ENTRIES_IN_REGISTERS 3 //APPEND_BATCH_SIZE-1
	#define APPEND_RDMA_PAYLOAD_SIZE 16 //APPEND_BATCH_SIZE*4 (4 bytes per Append payload)
	
	//No batching
	//#define APPEND_BATCH_SIZE 1
	//#define NUM_APPEND_ENTRIES_IN_REGISTERS 0
	//#define APPEND_RDMA_PAYLOAD_SIZE 4
#endif

typedef bit<32> batch_entry_num_t; //Used as entry-identifier for building append batches (8 likely enough, but 32 because compiler issues)
typedef bit<32> append_data_t; //data for append

typedef bit<32> rdma_write_len_t;
typedef bit<32> iCRC_t;
typedef bit<32> remote_key_t;
typedef bit<24> queue_pair_t;
typedef bit<24> psn_t; //Packet sequence number in RoCEv2

typedef bit<32> list_id_t; //List IDs in the Append primitive

typedef bit<16> qp_reg_index_t; //Used to store PSN for each QP. This is the index for that register

typedef bit<32> memory_slot_t; //shared by keywrite and append, both are limited to max 32b for different reasons
typedef bit<64> memory_address_t;

typedef bit<32> drop_counter_t; //This is used to halt QP traffic during resync

//Number of DTA-RDMA conversions to drop during QP resync period (allowing system to refresh)
#ifndef QP_RESYNC_PACKET_DROP_NUM
	//#define QP_RESYNC_PACKET_DROP_NUM 10000000 //10M
	//#define QP_RESYNC_PACKET_DROP_NUM 1000000 //1M
	#define QP_RESYNC_PACKET_DROP_NUM 100000 //100K
	//#define QP_RESYNC_PACKET_DROP_NUM 50000 //50K
	//#define QP_RESYNC_PACKET_DROP_NUM 10000 //10K (system dies)
#endif

//#define DISABLE_CONGESTION_HANDLING //Defining this one will drop congestion acks in Ingress, preventing PSN resync

typedef bit<8> dta_seqnum_t;

//Handling metadata bridging
typedef bit<8>  pkt_type_t;
const pkt_type_t PKT_TYPE_NORMAL = 1;
const pkt_type_t PKT_TYPE_MIRROR = 2;

//Handling mirror type
typedef bit<3> mirror_type_t;
const mirror_type_t MIRROR_TYPE_I2E = 1;
const mirror_type_t MIRROR_TYPE_E2E = 2;

//14 bytes
header ethernet_h
{
	bit<48> dstAddr;
	bit<48> srcAddr;
	bit<16> etherType;
}

//20 bytes
header ipv4_h
{
	bit<4> version;
	bit<4> ihl;
	bit<6> dscp;
	bit<2> ecn;
	bit<16> totalLen;
	bit<16> identification;
	bit<3> flags;
	bit<13> fragOffset;
	bit<8> ttl;
	bit<8> protocol;
	bit<16> hdrChecksum;
	ipv4_address_t srcAddr;
	ipv4_address_t dstAddr;
}

//8 bytes
header udp_h
{
	bit<16> srcPort;
	bit<16> dstPort;
	bit<16> length;
	bit<16> checksum;
}

header dta_ack_h
{
	dta_seqnum_t seqnum;
	bit<1> nack;
	bit<7> reserved;
}

header dta_base_h
{
	bit<8> opcode;
	#ifdef DO_NACK_TRACKING
		dta_seqnum_t seqnum;
		bit<1> immediate; //CPU should be informed of this report
		bit<1> retransmitable; //This report can be retransmitted, do seqnum tracking
		bit<6> reserved;
	#else
		bit<1> immediate;
		bit<7> reserved;
	#endif
	//bit<16> collectorID; //Do we need this field? Or maybe instead just use the IP?
}

//Shared between Key-Write and Key-Increment, but they have different sub-headers
header dta_keyval_static_h
{
	bit<8> redundancyLevel;
	telemetry_key_t key;
}
header dta_keyincrement_h
{
	keyincrement_counter_t counter;
}
//This will be shared between DTA and RDMA keywrite headers, to streamline conversion
header keywrite_data_h
{
	keyval_data_t data1;
	/*keyval_data_t data2;
	keyval_data_t data3;
	keyval_data_t data4;
	keyval_data_t data5;
	keyval_data_t data6;
	keyval_data_t data7;*/
}

header dta_append_static_h
{
	list_id_t listID;
	append_data_t data;
}

header dta_postcarder_h
{
	bit<32> key;
	hop_num_t hopNum;
	postcarder_data_t data;
}

//12 bytes
header infiniband_bth_h
{
	bit<8> opcode;
	bit<1> solicitedEvent;
	bit<1> migReq;
	bit<2> padCount;
	bit<4> transportHeaderVersion;
	bit<16> partitionKey;
	bit<1> fRes;
	bit<1> bRes;
	bit<6> reserved1;
	bit<24> destinationQP;
	bit<1> ackRequest;
	bit<7> reserved2;
	psn_t packetSequenceNumber;
}

//See Infiniband spec page 254
//16 bytes
header infiniband_reth_h
{
	memory_address_t virtualAddress;
	bit<32> rKey;
	bit<32> dmaLength;
}

//See Infiniband spec page 242
header infiniband_atomiceth_h
{
	memory_address_t virtualAddress;
	bit<32> rKey;
	bit<64> data;
	bit<64> compare;
}

//4+4 bytes
header rdma_payload_keyval_h
{
	telemetry_key_checksum_t checksum;
	//keyval_data_t data1; //This is replaced by the shared keywrite_data_h
}

//The append payload header. The size is dependent on the number of batched entries
header rdma_payload_append_h
{
	append_data_t data1;
	#if APPEND_BATCH_SIZE >= 2
		append_data_t data2;
	#endif
	#if APPEND_BATCH_SIZE >= 4
		append_data_t data3;
		append_data_t data4;
	#endif
	#if APPEND_BATCH_SIZE >= 8
		append_data_t data5;
		append_data_t data6;
		append_data_t data7;
		append_data_t data8;
	#endif
	#if APPEND_BATCH_SIZE == 16
		append_data_t data9;
		append_data_t data10;
		append_data_t data11;
		append_data_t data12;
		append_data_t data13;
		append_data_t data14;
		append_data_t data15;
		append_data_t data16;
	#endif
}

header rdma_payload_postcarder_h
{
	bit<32> data1;
	bit<32> data2;
	bit<32> data3;
	bit<32> data4;
	bit<32> data5;
}

//4 bytes
header infiniband_icrc_h
{
	bit<32> iCRC;
}


header mirror_h
{
	pkt_type_t pkt_type;
}

header mirror_bridged_metadata_h
{
	pkt_type_t pkt_type;
}

struct headers
{
	mirror_bridged_metadata_h bridged_md;
	ethernet_h ethernet;
	ipv4_h ipv4;
	udp_h udp;
	
	infiniband_bth_h bth;
	infiniband_reth_h reth;
	infiniband_atomiceth_h atomic_eth;
	
	#ifdef DO_NACK_TRACKING
		dta_ack_h dta_ack;
	#endif
	dta_base_h dta_base;
	dta_append_static_h dta_append;
	dta_postcarder_h dta_postcarder;
	rdma_payload_append_h rdma_payload_append;
	rdma_payload_postcarder_h rdma_payload_postcarder;
	
	
	dta_keyval_static_h dta_keyval;
	dta_keyincrement_h dta_keyincrement;
	
	rdma_payload_keyval_h rdma_payload_keyval;
	keywrite_data_h keywrite_data;
	
	infiniband_icrc_h icrc;
}

struct roce_icrc_fields_t
{
	/*
	infiniband_bth_h bth;
	infiniband_reth_h reth;
	infiniband_payload_h rdma_payload;
	*/
	
	//bth
	bit<8> bth_opcode;
	bit<1> bth_solicitedEvent;
	bit<1> bth_migReq;
	bit<2> bth_padCount;
	bit<4> bth_transportHeaderVersion;
	bit<16> bth_partitionKey;
	bit<1> bth_fRes;
	bit<1> bth_bRes;
	bit<6> bth_reserved1;
	bit<24> bth_destinationQP;
	bit<1> bth_ackRequest;
	bit<7> bth_reserved2;
	bit<24> bth_packetSequenceNumber;
	
	//reth
	memory_address_t reth_virtualAddress;
	bit<32> reth_rKey;
	bit<32> reth_dmaLength;
	
	//payload
	bit<32> payload_data1;
}

struct debug_digest_ingress_t
{
	debug_t debug;
	debug_t debug2;
}

struct ingress_metadata_t
{
	debug_t debug; //Used for debug data (included in digest)
	debug_t debug2;
	random_t random;
	
	bit<1> send_debug_data;
	bit<1> generate_report;
	bit<1> detected_change; //If a change was detected
	
	pkt_type_t pkt_type;
	MirrorId_t mirror_session;
	
	//telemetry_checksum_t telemetry_checksum;
	//keyval_data_t telemetry_data;
	//telemetry_key_t telemetry_key;
	telemetry_checksum_cache_index_t telemetry_checksum_cache_index;
	telemetry_checksum_t checksum_to_insert_into_cache;
	telemetry_checksum_t last_telemetry_checksum_cache_element;
	
	list_id_t list_reg_index; //This will simply be listID in append header
	batch_entry_num_t num_batched_items; //used to verify that an append batch is built
	append_data_t append_data;
	
	bit<1> batch_ready;
	
	#ifdef DO_NACK_TRACKING
		dta_seqnum_t prev_reporter_seqnum;
		bit<1> trigger_nack_response;
		ipv4_address_t ipAddr_tmp;
	#endif
}

struct egress_metadata_t
{
	bit<1> is_report_packet;
	debug_t debug;
	
	telemetry_key_checksum_t telemetry_key_checksum;
	
	redundancy_entry_num_t redundancy_entry_num;
	
	roce_icrc_fields_t roce_icrc_fields;
	
	psn_t rdma_psn;
	remote_key_t remote_key;
	queue_pair_t queue_pair;
	memory_address_t memory_address_start;
	memory_slot_t collector_num_storage_slots;
	memory_slot_t destination_memory_slot;
	memory_address_t memory_write_offset;
	
	//bit<32> destination_memory_address_1;
	//bit<32> destination_memory_address_2;
	
	bit<16> rdma_payload_length; //Payload length in bytes
	
	qp_reg_index_t qp_reg_index;
	
	
	//Used for QP resync
	PortId_t egress_port;
	drop_counter_t drop_counter;
	bit<1> is_congestion_ack;
	bit<1> prevent_rdma_generation; //flagging that RDMA shall NOT be generated for this packet
	
	postcarder_cache_index_t postcarder_cache_index;
	//postcarder_data_t postcarder_towrite;
	postcarder_data_t postcarder_data1;
	postcarder_data_t postcarder_data2;
	postcarder_data_t postcarder_data3;
	postcarder_data_t postcarder_data4;
	postcarder_data_t postcarder_data5;
	bit<1> postcarder_ready_for_compile;
	bit<1> postcarder_collision;
	bit<32> stored_flowID;
	bit<8> cache_counter;
	
	bit<64> icrc_part_1;
	bit<64> icrc_part_2;
	bit<64> icrc_part_3;
	bit<64> icrc_part_4;
	bit<64> icrc_part_5;
	bit<64> icrc_part_6;
	bit<64> icrc_part_7;
	bit<64> icrc_part_8;
	bit<32> icrc_final;
}

parser TofinoIngressParser(packet_in pkt, inout ingress_metadata_t ig_md, out ingress_intrinsic_metadata_t ig_intr_md)
{
	state start
	{
		pkt.extract(ig_intr_md);
		transition select(ig_intr_md.resubmit_flag)
		{
			1 : parse_resubmit;
			0 : parse_port_metadata;
		}
	}

	state parse_resubmit
	{
		transition reject;
	}

	state parse_port_metadata
	{
		pkt.advance(64); //Tofino 1
		transition accept;
	}
}

parser SwitchIngressParser(packet_in pkt, out headers hdr, out ingress_metadata_t ig_md, out ingress_intrinsic_metadata_t ig_intr_md)
{
	TofinoIngressParser() tofino_parser;
	
	state start 
	{
		tofino_parser.apply(pkt, ig_md, ig_intr_md);
		transition parse_ethernet;
	}
	
	state parse_ethernet
	{
		pkt.extract(hdr.ethernet);
		transition select(hdr.ethernet.etherType)
		{
			ETHERTYPE_IPV4: parse_ipv4;
			default: accept;
		}
	}
	
	state parse_ipv4
	{
		pkt.extract(hdr.ipv4);
		
		transition select(hdr.ipv4.protocol)
		{
			IPv4_PROTO_UDP: parse_udp;
			default: accept;
		}
	}
	
	state parse_udp
	{
		pkt.extract(hdr.udp);
		
		transition select(hdr.udp.dstPort)
		{
			DTA_PORT_NUMBER: parse_dta_base;
			ROCEV2_UDP_PORT: parse_rocev2_bth;
			default: accept;
		}
	}
	
	state parse_rocev2_bth
	{
		pkt.extract(hdr.bth);
		
		transition accept;
	}
	
	state parse_dta_base
	{
		pkt.extract(hdr.dta_base);
		
		transition select(hdr.dta_base.opcode)
		{
			DTA_OPCODE_KEYWRITE: parse_dta_keyval;
			DTA_OPCODE_KEYINCREMENT: parse_dta_keyval;
			DTA_OPCODE_APPEND: parse_dta_append; 
			DTA_OPCODE_POSTCARDER: parse_dta_postcarder; 
			default: accept;
		}
	}
	
	state parse_dta_keyval
	{
		pkt.extract(hdr.dta_keyval);
		
		transition select(hdr.dta_base.opcode)
		{
			DTA_OPCODE_KEYWRITE: parse_keywrite_data;
			DTA_OPCODE_KEYINCREMENT: parse_keyincrement_counter; 
			default: reject; //Must be one of those, wth
		}
	}
	state parse_keywrite_data
	{
		pkt.extract(hdr.keywrite_data);
		
		transition accept;
	}
	state parse_keyincrement_counter
	{
		pkt.extract(hdr.dta_keyincrement);
		
		transition accept;
	}
	state parse_dta_append
	{
		pkt.extract(hdr.dta_append);
		
		transition accept;
	}
	state parse_dta_postcarder
	{
		pkt.extract(hdr.dta_postcarder);
		
		transition accept;
	}
}

control ControlAppendBatchHandling(inout headers hdr, inout ingress_metadata_t ig_md, inout ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md)
{
	Register<batch_entry_num_t, list_id_t>(MAX_SUPPORTED_QPS) reg_num_batched_elements;
	RegisterAction<batch_entry_num_t, list_id_t, batch_entry_num_t>(reg_num_batched_elements) get_num_batched = {
		void apply(inout batch_entry_num_t num_batched, out batch_entry_num_t output)
		{
			output = num_batched;
			
			if(num_batched == NUM_APPEND_ENTRIES_IN_REGISTERS)
				num_batched = 0;
			else
				num_batched = num_batched + 1;
		}
	};
	
	//This will be the same for all batch elements, so create a shared define.
	//return back the old value (in case this is rdma-ready). They will they all contain the same value (of last append element)
	//Update the batch data (in case this is batch builder)
	#define APPEND_EXCHANGE_ACTION \
	void apply(inout append_data_t stored_data, out append_data_t output) \
	{\
		output = stored_data; \
		stored_data = ig_md.append_data; \
	}
	#define APPEND_STORE_ACTION \
	void apply(inout append_data_t stored_data, out append_data_t output) \
	{\
		stored_data = ig_md.append_data; \
	}
	#define APPEND_GET_ACTION \
	void apply(inout append_data_t stored_data, out append_data_t output) \
	{\
		output = stored_data; \
	}
	
	//Define registers used for append batch-building.
	//Re-use action for both store and get, limiting footprint
	#if APPEND_BATCH_SIZE >= 2
		Register<append_data_t, list_id_t>(MAX_SUPPORTED_QPS) reg_batch_1;
		RegisterAction<append_data_t, list_id_t, append_data_t>(reg_batch_1) exchange_batch_1 = { APPEND_EXCHANGE_ACTION };
	#endif
	#if APPEND_BATCH_SIZE >= 4
		Register<append_data_t, list_id_t>(MAX_SUPPORTED_QPS) reg_batch_2;
		Register<append_data_t, list_id_t>(MAX_SUPPORTED_QPS) reg_batch_3;
		RegisterAction<append_data_t, list_id_t, append_data_t>(reg_batch_2) exchange_batch_2 = { APPEND_EXCHANGE_ACTION };
		RegisterAction<append_data_t, list_id_t, append_data_t>(reg_batch_3) exchange_batch_3 = { APPEND_EXCHANGE_ACTION };
	#endif
	#if APPEND_BATCH_SIZE >= 8
		Register<append_data_t, list_id_t>(MAX_SUPPORTED_QPS) reg_batch_4;
		Register<append_data_t, list_id_t>(MAX_SUPPORTED_QPS) reg_batch_5;
		Register<append_data_t, list_id_t>(MAX_SUPPORTED_QPS) reg_batch_6;
		Register<append_data_t, list_id_t>(MAX_SUPPORTED_QPS) reg_batch_7;
		RegisterAction<append_data_t, list_id_t, append_data_t>(reg_batch_4) exchange_batch_4 = { APPEND_EXCHANGE_ACTION };
		RegisterAction<append_data_t, list_id_t, append_data_t>(reg_batch_5) exchange_batch_5 = { APPEND_EXCHANGE_ACTION };
		RegisterAction<append_data_t, list_id_t, append_data_t>(reg_batch_6) exchange_batch_6 = { APPEND_EXCHANGE_ACTION };
		RegisterAction<append_data_t, list_id_t, append_data_t>(reg_batch_7) exchange_batch_7 = { APPEND_EXCHANGE_ACTION };
	#endif
	#if APPEND_BATCH_SIZE == 16
		Register<append_data_t, list_id_t>(MAX_SUPPORTED_QPS) reg_batch_8;
		Register<append_data_t, list_id_t>(MAX_SUPPORTED_QPS) reg_batch_9;
		Register<append_data_t, list_id_t>(MAX_SUPPORTED_QPS) reg_batch_10;
		Register<append_data_t, list_id_t>(MAX_SUPPORTED_QPS) reg_batch_11;
		Register<append_data_t, list_id_t>(MAX_SUPPORTED_QPS) reg_batch_12;
		Register<append_data_t, list_id_t>(MAX_SUPPORTED_QPS) reg_batch_13;
		Register<append_data_t, list_id_t>(MAX_SUPPORTED_QPS) reg_batch_14;
		Register<append_data_t, list_id_t>(MAX_SUPPORTED_QPS) reg_batch_15;
		RegisterAction<append_data_t, list_id_t, append_data_t>(reg_batch_8) exchange_batch_8 = { APPEND_EXCHANGE_ACTION };
		RegisterAction<append_data_t, list_id_t, append_data_t>(reg_batch_9) exchange_batch_9 = { APPEND_EXCHANGE_ACTION };
		RegisterAction<append_data_t, list_id_t, append_data_t>(reg_batch_10) exchange_batch_10 = { APPEND_EXCHANGE_ACTION };
		RegisterAction<append_data_t, list_id_t, append_data_t>(reg_batch_11) exchange_batch_11 = { APPEND_EXCHANGE_ACTION };
		RegisterAction<append_data_t, list_id_t, append_data_t>(reg_batch_12) exchange_batch_12 = { APPEND_EXCHANGE_ACTION };
		RegisterAction<append_data_t, list_id_t, append_data_t>(reg_batch_13) exchange_batch_13 = { APPEND_EXCHANGE_ACTION };
		RegisterAction<append_data_t, list_id_t, append_data_t>(reg_batch_14) exchange_batch_14 = { APPEND_EXCHANGE_ACTION };
		RegisterAction<append_data_t, list_id_t, append_data_t>(reg_batch_15) exchange_batch_15 = { APPEND_EXCHANGE_ACTION };
	#endif
	
	apply
	{
		hdr.rdma_payload_append.setValid(); //The Append RDMA payload will follow the packet into egress (unless it is dropped of course)
		
		ig_md.list_reg_index = hdr.dta_append.listID;
		
		//Get the number of append items that have been batched so far for this list
		ig_md.num_batched_items = get_num_batched.execute(ig_md.list_reg_index);
		
		if( ig_md.num_batched_items == NUM_APPEND_ENTRIES_IN_REGISTERS ) //Batch is built!
			ig_md.batch_ready = 1; //TODO: Set according to counting register
		else //Batch is not yet built
		{
			ig_md.batch_ready = 0;
			//ig_md.batch_ready = 1; //Used while benchmarking append batching performance. Egress POV sees 16-fold increase in data
		}
		
		
		//Fix endianness of telemetry data
		ig_md.append_data = hdr.dta_append.data[7:0] ++
							hdr.dta_append.data[15:8] ++
							hdr.dta_append.data[23:16] ++
							hdr.dta_append.data[31:24];
		
		//Extract and process each entry conditionally (either for updating or retrieving, depending on who does it, but do both simultaneously)
		#if APPEND_BATCH_SIZE >= 2
			if( ig_md.num_batched_items == 0 || ig_md.batch_ready == 1 )
				hdr.rdma_payload_append.data1 = exchange_batch_1.execute(ig_md.list_reg_index);
		#endif
		#if APPEND_BATCH_SIZE >= 4
			if( ig_md.num_batched_items == 1 || ig_md.batch_ready == 1 )
				hdr.rdma_payload_append.data2 = exchange_batch_2.execute(ig_md.list_reg_index);
			if( ig_md.num_batched_items == 2 || ig_md.batch_ready == 1 )
				hdr.rdma_payload_append.data3 = exchange_batch_3.execute(ig_md.list_reg_index);
		#endif
		#if APPEND_BATCH_SIZE >= 8
			if( ig_md.num_batched_items == 3 || ig_md.batch_ready == 1 )
				hdr.rdma_payload_append.data4 = exchange_batch_4.execute(ig_md.list_reg_index);
			if( ig_md.num_batched_items == 4 || ig_md.batch_ready == 1 )
				hdr.rdma_payload_append.data5 = exchange_batch_5.execute(ig_md.list_reg_index);
			if( ig_md.num_batched_items == 5 || ig_md.batch_ready == 1 )
				hdr.rdma_payload_append.data6 = exchange_batch_6.execute(ig_md.list_reg_index);
			if( ig_md.num_batched_items == 6 || ig_md.batch_ready == 1 )
				hdr.rdma_payload_append.data7 = exchange_batch_7.execute(ig_md.list_reg_index);
		#endif
		#if APPEND_BATCH_SIZE == 16
			if( ig_md.num_batched_items == 7 || ig_md.batch_ready == 1 )
				hdr.rdma_payload_append.data8 = exchange_batch_8.execute(ig_md.list_reg_index);
			if( ig_md.num_batched_items == 8 || ig_md.batch_ready == 1 )
				hdr.rdma_payload_append.data9 = exchange_batch_9.execute(ig_md.list_reg_index);
			if( ig_md.num_batched_items == 9 || ig_md.batch_ready == 1 )
				hdr.rdma_payload_append.data10 = exchange_batch_10.execute(ig_md.list_reg_index);
			if( ig_md.num_batched_items == 10 || ig_md.batch_ready == 1 )
				hdr.rdma_payload_append.data11 = exchange_batch_11.execute(ig_md.list_reg_index);
			if( ig_md.num_batched_items == 11 || ig_md.batch_ready == 1 )
				hdr.rdma_payload_append.data12 = exchange_batch_12.execute(ig_md.list_reg_index);
			if( ig_md.num_batched_items == 12 || ig_md.batch_ready == 1 )
				hdr.rdma_payload_append.data13 = exchange_batch_13.execute(ig_md.list_reg_index);
			if( ig_md.num_batched_items == 13 || ig_md.batch_ready == 1 )
				hdr.rdma_payload_append.data14 = exchange_batch_14.execute(ig_md.list_reg_index);
			if( ig_md.num_batched_items == 14 || ig_md.batch_ready == 1 )
				hdr.rdma_payload_append.data15 = exchange_batch_15.execute(ig_md.list_reg_index);
		#endif
		
		//Last one doesn't need to be stored, just take from DTA header
		#if APPEND_BATCH_SIZE == 1
			hdr.rdma_payload_append.data1 = ig_md.append_data; 
		#endif
		#if APPEND_BATCH_SIZE == 2
			hdr.rdma_payload_append.data2 = ig_md.append_data; 
		#endif
		#if APPEND_BATCH_SIZE == 4
			hdr.rdma_payload_append.data4 = ig_md.append_data; 
		#endif
		#if APPEND_BATCH_SIZE == 8
			hdr.rdma_payload_append.data8 = ig_md.append_data; 
		#endif
		#if APPEND_BATCH_SIZE == 16
			hdr.rdma_payload_append.data16 = ig_md.append_data; 
		#endif
		
		
		//If the append batch is not ready, drop this append operation (will not generate RDMA already)
		if( ig_md.batch_ready == 0 )  
			ig_intr_dprsr_md.drop_ctl = 1;
		
	}
}

control ControlProcessDTAPacket(inout headers hdr, inout ingress_metadata_t ig_md, inout ingress_intrinsic_metadata_for_tm_t ig_intr_tm_md, inout ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md)
{
	ControlAppendBatchHandling() AppendBatchHandling;
	
	#ifdef DO_NACK_TRACKING
		Register<dta_seqnum_t, bit<16>>(NUM_TRACKED_NACKS,0) reg_nack_tracker;
		RegisterAction<dta_seqnum_t, bit<16>, dta_seqnum_t>(reg_nack_tracker) proc_nack_tracker = {
			void apply(inout dta_seqnum_t seqnum, out dta_seqnum_t output)
			{
				//TODO: only increment when the header-held value is correct! 
				if( seqnum == hdr.dta_base.seqnum-1 ) //The incoming sequence number is valid :)
					seqnum = seqnum + 1;
				
				output = seqnum;
			}
		};
	#endif
	
	/*
	//This is used temporarily during numQp test (to ensure listID round-robin)
	Register<list_id_t, bit<1>>(1,1) reg_track_listid;
	RegisterAction<list_id_t, bit<1>, list_id_t>(reg_track_listid) get_list_id = {
		void apply(inout list_id_t list_id, out list_id_t output)
		{
			if(list_id == 512)
				list_id = 1; //reserving 0 for throughput measurement
			else
				list_id = list_id + 1;
			output = list_id;
		}
	};
	*/
	
	
	//TODO: generalize for key-increment and key-write
	//Name is currently misleading, it's applied for both
	/*
	 * Ipv4 destination required for egress port
	 * redundancy level is required to know number of clones (therefore mcastgroup)
	 */
	action prep_MultiWrite(bit<16> mcast_grp)
	{
		ig_intr_tm_md.mcast_grp_a = mcast_grp;
		ig_md.debug = (debug_t)mcast_grp;
	}
	table tbl_Prep_KeyWrite
	{
		key = {
			hdr.ipv4.dstAddr: exact;
			hdr.dta_keyval.redundancyLevel: exact;
		}
		actions = {
			prep_MultiWrite;
			@defaultonly NoAction;
		}
		default_action = NoAction;
		size=1024;
	}
	
	#ifdef DO_NACK_TRACKING
	action craft_nack()
	{
		//Remove DTA headers
		hdr.dta_base.setInvalid();
		hdr.dta_keyval.setInvalid();
		hdr.keywrite_data.setInvalid();
		hdr.dta_append.setInvalid();
		
		//Add DTA ack header
		hdr.dta_ack.setValid();
		
		//Swap the IP addresses (to send back to reporter switch)
		ig_md.ipAddr_tmp = hdr.ipv4.srcAddr;
		hdr.ipv4.srcAddr = hdr.ipv4.dstAddr;
		hdr.ipv4.dstAddr = ig_md.ipAddr_tmp;
		
		hdr.udp.dstPort = DTA_ACK_PORT_NUMBER; //Signal that this is a DTA ack
		
		hdr.dta_ack.seqnum = ig_md.prev_reporter_seqnum; //Send the previous ACK (expected one -1) as response.
		hdr.dta_ack.nack = 1; //This is a NACK :)
	}
	#endif
	
	apply
	{
		ig_md.debug = 0x69;
		
		//Prepare for DTA operation processin in egress
		if( hdr.dta_base.opcode == DTA_OPCODE_KEYWRITE || hdr.dta_base.opcode == DTA_OPCODE_KEYINCREMENT ) //Key-value operations
			tbl_Prep_KeyWrite.apply();
		else if( hdr.dta_base.opcode == DTA_OPCODE_APPEND ) //Append-to-List operation
		{
			//hdr.dta_append.listID = get_list_id.execute(0); //Temporary during num QP test, ensuring list round-robin
			AppendBatchHandling.apply(hdr, ig_md, ig_intr_dprsr_md);
		}
		
		#ifdef DO_NACK_TRACKING
			if(hdr.dta_base.retransmitable == 1) //Only do seqnum tracking fo retransmitable packets
			{
				//TODO: Make unique per-reporter indexes here
				ig_md.prev_reporter_seqnum = proc_nack_tracker.execute(0);
				//ig_md.prev_reporter_seqnum = ig_md.prev_reporter_seqnum+1;
				if( hdr.dta_base.seqnum != ig_md.prev_reporter_seqnum ) //If the incoming seqnum is not the same that the register returned back (they should be if no data gaps)
				{
					ig_md.trigger_nack_response = 1;
					//ig_intr_dprsr_md.drop_ctl = 1; //For now just drop reports with invalid seqnum (to get tracker numbers)
					craft_nack(); //Craft a NACK
				}
			}
		#endif
	}
}

control SwitchIngress(inout headers hdr, inout ingress_metadata_t ig_md, in ingress_intrinsic_metadata_t ig_intr_md, in ingress_intrinsic_metadata_from_parser_t ig_intr_prsr_md, inout ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md, inout ingress_intrinsic_metadata_for_tm_t ig_intr_tm_md)
{
	ControlProcessDTAPacket() ProcessDTAPacket;
	
	action forward(PortId_t port)
	{
		ig_intr_tm_md.ucast_egress_port = port; //Set egress port
		hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
	}
	action to_cpu()
	{
		ig_intr_tm_md.ucast_egress_port = 64;
		ig_md.debug = 666;
	}
	action drop()
	{
		ig_intr_dprsr_md.drop_ctl = 1;
	}
	table tbl_forward
	{
		key = {
			hdr.ipv4.dstAddr: exact;
		}
		actions = {
			forward;
			to_cpu;
			drop;
		}
		default_action = to_cpu;
		//default_action = drop;
		size=1024;
	}
	
	apply
	{
		ig_md.debug = 0;
		ig_md.send_debug_data = 0;
		
		//Process a DTA packet
		if( hdr.dta_base.isValid() )
			ProcessDTAPacket.apply(hdr, ig_md, ig_intr_tm_md, ig_intr_dprsr_md);
		
		if( !hdr.dta_keyval.isValid() ) //KeyWrite and KeyIncrement packets will skip the forward table (they instead do multicasting)
			tbl_forward.apply();
		
		
		
		//Bounce back RDMA acks to same port they came from, to ensure they end up at correct egress pipe
		if( hdr.bth.isValid() )
		{
			if(hdr.bth.opcode == 17 && hdr.ipv4.srcAddr == 0x0a000033) //IP is hard-coded for now
			{
				ig_intr_tm_md.ucast_egress_port = ig_intr_md.ingress_port; //Bounce
				ig_md.send_debug_data = 1;
				ig_md.debug = (debug_t)hdr.bth.packetSequenceNumber;
				ig_md.debug2 = (debug_t)hdr.bth.destinationQP;
				#ifdef DISABLE_CONGESTION_HANDLING
					ig_intr_dprsr_md.drop_ctl = 1;
				#endif
			}
		}
		else
		{
			ig_md.debug = 0;
			ig_md.debug2 = 0;
		}
		
		
		//TEMPORARY, REMOVE! Forces forwarding from-collector traffic to CPU for analysis
		//if( ig_intr_md.ingress_port == 152 ) //If from collector
			//ig_intr_tm_md.ucast_egress_port = 64; //Send to CPU for analysis
		
		//Force Append traffic to emit to switch CPU for analysis
		//if( hdr.dta_append.isValid() )
			//ig_intr_tm_md.ucast_egress_port = 64;
		
		
		
		//Prepare bridging metadata to egress
		hdr.bridged_md.setValid();
		hdr.bridged_md.pkt_type = PKT_TYPE_NORMAL; //Mirrors will overwrite this one
		
		
		//ig_md.send_debug_data = 1;
	}
}

control SwitchIngressDeparser(packet_out pkt, inout headers hdr, in ingress_metadata_t ig_md, in ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md)
{
	Digest<debug_digest_ingress_t>() debug_digest;
	Mirror() mirror;
	
	apply
	{
		//Digest
		if( ig_md.send_debug_data == 1 )
		{
			debug_digest.pack({
				ig_md.debug,
				ig_md.debug2
			});
		}
		
		//Mirroring
		if (ig_intr_dprsr_md.mirror_type == MIRROR_TYPE_I2E)
		{
			//Emit mirror with mirror_h header appended.
			mirror.emit<mirror_h>(ig_md.mirror_session, {ig_md.pkt_type});
		}
		
		
		pkt.emit(hdr);
	}
}

parser TofinoEgressParser(packet_in pkt, out egress_intrinsic_metadata_t eg_intr_md)
{
	state start
	{
		pkt.extract(eg_intr_md);
		transition accept;
	}
}

parser SwitchEgressParser(packet_in pkt, out headers hdr, out egress_metadata_t eg_md, out egress_intrinsic_metadata_t eg_intr_md)
{
	TofinoEgressParser() tofino_parser;

	state start
	{
		tofino_parser.apply(pkt, eg_intr_md);
		transition parse_metadata;
	}
	
	state parse_metadata
	{
		mirror_h mirror_md = pkt.lookahead<mirror_h>();
		
		transition select(mirror_md.pkt_type)
		{
			PKT_TYPE_MIRROR: parse_mirror_md;
			PKT_TYPE_NORMAL: parse_bridged_md;
			default: accept;
		}
	}
	
	state parse_bridged_md
	{
		pkt.extract(hdr.bridged_md);
		transition parse_ethernet;
	}
	
	state parse_mirror_md
	{
		eg_md.is_report_packet = 1;
		
		mirror_h mirror_md;
		pkt.extract(mirror_md);
		transition parse_ethernet;
	}
	
	state parse_ethernet
	{
		pkt.extract(hdr.ethernet);
		transition select(hdr.ethernet.etherType)
		{
			ETHERTYPE_IPV4: parse_ipv4;
			default: accept;
		}
	}
	
	state parse_ipv4
	{
		pkt.extract(hdr.ipv4);
		
		transition select(hdr.ipv4.protocol)
		{
			IPv4_PROTO_UDP: parse_udp;
			default: accept;
		}
	}
	
	state parse_udp
	{
		pkt.extract(hdr.udp);
		
		transition select(hdr.udp.dstPort)
		{
			DTA_PORT_NUMBER: parse_dta_base;
			ROCEV2_UDP_PORT: parse_rocev2_bth;
			default: accept;
		}
	}
	
	state parse_rocev2_bth
	{
		pkt.extract(hdr.bth);
		
		eg_md.queue_pair = hdr.bth.destinationQP;
		transition accept; //No need to parse deeper than the BTH at the moment.
	}
	
	state parse_dta_base
	{
		pkt.extract(hdr.dta_base);
		
		transition select(hdr.dta_base.opcode)
		{
			DTA_OPCODE_KEYWRITE: parse_dta_keyval;
			DTA_OPCODE_KEYINCREMENT: parse_dta_keyval; 
			DTA_OPCODE_APPEND: parse_dta_append; 
			default: accept;
		}
	}
	
	state parse_dta_keyval
	{
		pkt.extract(hdr.dta_keyval);
		
		transition select(hdr.dta_base.opcode)
		{
			DTA_OPCODE_KEYWRITE: parse_keywrite_data;
			DTA_OPCODE_KEYINCREMENT: parse_keyincrement_counter; 
			default: reject; //Must be one of those, wth
		}
	}
	state parse_keywrite_data
	{
		pkt.extract(hdr.keywrite_data);
		
		transition accept;
	}
	state parse_keyincrement_counter
	{
		pkt.extract(hdr.dta_keyincrement);
		
		transition accept;
	}
	
	state parse_dta_append
	{
		pkt.extract(hdr.dta_append);
		pkt.extract(hdr.rdma_payload_append);
		
		transition accept;
	}
}

//Ratelimiting in case of resync (dropping X packets)
//On a per-egress-port basis (because it's the NIC we need to rate limit anyway)
//We now also place NACK tracking here
control ControlRDMARatelimit(inout headers hdr, inout egress_metadata_t eg_md)
{
	Register<drop_counter_t, PortId_t>(1024,0) reg_rdma_drop_counter;
	RegisterAction<drop_counter_t, PortId_t, drop_counter_t>(reg_rdma_drop_counter) get_drop_counter = {
		void apply(inout drop_counter_t counter, out drop_counter_t output)
		{
			//Decrement counter towards 0
			if( counter > 0 )
				counter = counter - 1;
			output = counter;
		}
	};
	RegisterAction<drop_counter_t, PortId_t, drop_counter_t>(reg_rdma_drop_counter) initiate_drop_counting = {
		void apply(inout drop_counter_t counter, out drop_counter_t output)
		{
			//Start dropping subsequent traffic this many times
			counter = QP_RESYNC_PACKET_DROP_NUM;
			output = counter;
		}
	};
	
	action set_qp_reg_num(qp_reg_index_t qp_reg_index)
	{
		eg_md.qp_reg_index = qp_reg_index;
	}
	table tbl_get_qp_reg_num
	{
		key = {
			eg_md.queue_pair: exact;
		}
		actions = {
			set_qp_reg_num;
			NoAction;
		}
		//default_action = to_cpu;
		default_action = NoAction;
		size=1024;
	}
	
	apply
	{
		if(eg_md.is_congestion_ack == 1)
		{
			initiate_drop_counting.execute(eg_md.egress_port); //Start forcing packet drops for this egress port
			tbl_get_qp_reg_num.apply(); //This is needed to resync the PSN counter
		}
		else if(hdr.dta_base.isValid()) //DTA traffic
		{
			eg_md.drop_counter = get_drop_counter.execute(eg_md.egress_port);
			
			if( eg_md.drop_counter > 0 ) //If this packet should be dropped (ignore RDMA generation)
				eg_md.prevent_rdma_generation = 1; //This will bypass PSN incrementor and drop in deparser
		}
		
	}
}


//This assumes that the append RDMA payload is already prepared in the ingress batching-stage
control ControlPrepareAppend(inout headers hdr, inout egress_metadata_t eg_md)
{
	//Handles the HEAD pointer in the ring buffer
	Register<memory_slot_t, qp_reg_index_t>(MAX_SUPPORTED_QPS) reg_head_pointer;
	RegisterAction<memory_slot_t, qp_reg_index_t, memory_slot_t>(reg_head_pointer) get_head_offset = {
		void apply(inout memory_slot_t head, out memory_slot_t output)
		{
			//This is the correct functionality
			if( head < eg_md.collector_num_storage_slots )
			{
				output = head;
				head = head + APPEND_BATCH_SIZE; //Move head according to how many elements are included in the batch
			}
			else
			{
				
				output = 0;
				head = 0; //Reset the head from 0 (start of ring buffer)
			}
			//This functionality disables HEAD wrap-around (used during PSN resync tests)
			//output = head;
			//head = head + APPEND_BATCH_SIZE;
		}
	};
	
	//TODO: re-merge tables. No need anymore
	//Assuming that dstIP is already correct towards the right list collector
	action set_server_info_1(remote_key_t remote_key, queue_pair_t queue_pair, memory_address_t memory_address_start)
	{
		eg_md.remote_key = remote_key;
		eg_md.queue_pair = queue_pair;
		eg_md.memory_address_start = memory_address_start;
	}
	table tbl_getCollectorMetadataFromListID_1
	{
		key = {
			hdr.dta_append.listID: exact;
		}
		actions = {
			set_server_info_1;
		}
		size = MAX_SUPPORTED_QPS; //A single translator can't reasonable be responsible for more than this!
	}
	action set_server_info_2(memory_slot_t collector_num_storage_slots, qp_reg_index_t qp_reg_index)
	{
		eg_md.collector_num_storage_slots = collector_num_storage_slots;
		eg_md.qp_reg_index = qp_reg_index;
	}
	table tbl_getCollectorMetadataFromListID_2
	{
		key = {
			hdr.dta_append.listID: exact;
		}
		actions = {
			set_server_info_2;
		}
		size = MAX_SUPPORTED_QPS; //A single translator can't reasonable be responsible for more than this!
	}
	
	apply
	{
		tbl_getCollectorMetadataFromListID_1.apply();
		tbl_getCollectorMetadataFromListID_2.apply();
		
		eg_md.rdma_payload_length = APPEND_RDMA_PAYLOAD_SIZE; //20B, data*5 (for batching)
		
		//Deprecated, moved into Ingress
		//Process batching. This writes into payload, and flags to not do RDMA if batch is not fully built
		//AppendBatchHandling.apply(hdr, eg_md);
		
		//Get the slot that the HEAD is currently pointing to
		//if( eg_md.doRDMACreation == 1 ) //Only update the HEAD counter if the batch is full
		eg_md.destination_memory_slot = get_head_offset.execute(eg_md.qp_reg_index);
		//eg_md.destination_memory_slot = 0; //Used to benchmark RDMA baseline (only write to first ring buffer slot)
		
		//Convert the slot into memory offset
		eg_md.memory_write_offset = (memory_address_t)(eg_md.destination_memory_slot);
		eg_md.memory_write_offset = eg_md.memory_write_offset*4; //each slot is 4 bytes
	}
}

control ControlPrepareKeyWrite(inout headers hdr, inout egress_metadata_t eg_md)
{
	Hash<memory_slot_t>(HashAlgorithm_t.CRC32) hash_memory_slot;
	
	//This are assuming that the redundancies are processed back-to-back. A single counter then suffices
	Register<redundancy_entry_num_t, bit<1>>(MAX_SUPPORTED_QPS) reg_redundancy_iterator;
	RegisterAction<redundancy_entry_num_t, bit<1>, redundancy_entry_num_t>(reg_redundancy_iterator) get_redundancy_number = {
		void apply(inout redundancy_entry_num_t stored, out redundancy_entry_num_t output)
		{
			output = stored;
			
			
			//Either increment or reset n
			if(stored >= hdr.dta_keyval.redundancyLevel - 1)
				stored = 0;
			else
				stored = stored + 1;
			
		}
	};
	
	//Only supporting a single keywrite store per collector (to support multiple, include some storage ID in packet and here)
	action set_server_info(remote_key_t remote_key, queue_pair_t queue_pair, memory_address_t memory_address_start, memory_slot_t collector_num_storage_slots, qp_reg_index_t qp_reg_index)
	{
		eg_md.remote_key = remote_key;
		eg_md.queue_pair = queue_pair;
		eg_md.memory_address_start = memory_address_start;
		eg_md.collector_num_storage_slots = collector_num_storage_slots;
		eg_md.qp_reg_index = qp_reg_index;
	}
	table tbl_getCollectorMetadataFromIP
	{
		key = {
			hdr.ipv4.dstAddr: exact;
		}
		actions = {
			set_server_info;
		}
		size = MAX_SUPPORTED_QPS; //A single translator can't reasonable be responsible for more than this!
	}
	
	
	/*
	 * Hack to allow modulo for powers of 2, bounding the hashed memory slot to available slots
	 * We are assuming that there are a max of 2^32 memory slots in the collector (likely less, depending on size of rest of memory calculating components)
	 */
	action bound_memory_slot(memory_slot_t mask)
	{
		eg_md.destination_memory_slot = eg_md.destination_memory_slot & mask;
	}
	table tbl_bound_slot
	{
		key = {
			eg_md.collector_num_storage_slots: exact;
		}
		actions = {
			bound_memory_slot;
		}
		const entries = {
			2: 				bound_memory_slot(0x00000001);
			4: 				bound_memory_slot(0x00000003);
			8: 				bound_memory_slot(0x00000007);
			16: 			bound_memory_slot(0x0000000f);
			32: 			bound_memory_slot(0x0000001f);
			64: 			bound_memory_slot(0x0000003f);
			128: 			bound_memory_slot(0x0000007f);
			256: 			bound_memory_slot(0x000000ff);
			512: 			bound_memory_slot(0x000001ff);
			1024: 			bound_memory_slot(0x000003ff);
			2048: 			bound_memory_slot(0x000007ff);
			4096: 			bound_memory_slot(0x00000fff);
			8192: 			bound_memory_slot(0x00001fff);
			16384: 			bound_memory_slot(0x00003fff);
			32768: 			bound_memory_slot(0x00007fff);
			65536: 			bound_memory_slot(0x0000ffff);
			131072: 		bound_memory_slot(0x0001ffff);
			262144: 		bound_memory_slot(0x0003ffff);
			524288: 		bound_memory_slot(0x0007ffff);
			1048576: 		bound_memory_slot(0x000fffff);
			2097152: 		bound_memory_slot(0x001fffff);
			4194304: 		bound_memory_slot(0x003fffff);
			8388608: 		bound_memory_slot(0x007fffff);
			16777216: 		bound_memory_slot(0x00ffffff);
			33554432: 		bound_memory_slot(0x01ffffff);
			67108864: 		bound_memory_slot(0x03ffffff);
			134217728: 		bound_memory_slot(0x07ffffff);
			268435456: 		bound_memory_slot(0x0fffffff);
			536870912: 		bound_memory_slot(0x1fffffff);
			1073741824: 	bound_memory_slot(0x3fffffff);
			2147483648: 	bound_memory_slot(0x7fffffff);
			//4294967296: 	bound_memory_slot(0xffffffff); //does not fit in 32-bit
			
		}
		size=64;
	}
	
	//The actual data is just kept unchanged from the parsed DTA packet, to streamline processing. This is just checksum
	action setRDMAPayload()
	{
		hdr.rdma_payload_keyval.setValid();
		
		eg_md.rdma_payload_length = KEYWRITE_RDMA_PAYLOAD_SIZE; //4+4B, checksum+data
		
		//Write checksum with corrected endianness
		hdr.rdma_payload_keyval.checksum = eg_md.telemetry_key_checksum[7:0] ++
									eg_md.telemetry_key_checksum[15:8] ++
									eg_md.telemetry_key_checksum[23:16] ++
									eg_md.telemetry_key_checksum[31:24];
		
		
		//Disabled, let the collector handle endianness instead, allowing better data size scaling
		/*
		hdr.rdma_payload_keyval.data1 = hdr.dta_keywrite.data[7:0] ++
									hdr.dta_keywrite.data[15:8] ++
									hdr.dta_keywrite.data[23:16] ++
									hdr.dta_keywrite.data[31:24];
		*/
	}
	
	apply
	{
		//TODO: make this iterate over N! One for each packet in egress
		eg_md.redundancy_entry_num = get_redundancy_number.execute(0);; //retrieve n
		
		//Map the IP into collector metadata
		tbl_getCollectorMetadataFromIP.apply();
		
		setRDMAPayload();
		
		//Hash the key and (n in N) into a memory address
		@stage(1)
		{
			//Hash into memory slot (without bounding to memory size)
			//eg_md.destination_memory_slot = hash_memory_slot.get({hdr.dta_keywrite.key, eg_md.redundancy_entry_num});
			
			//Hash into memory with fixed endianness (speeds up querying)
			eg_md.destination_memory_slot = hash_memory_slot.get({hdr.dta_keyval.key[7:0] ++ hdr.dta_keyval.key[15:8] ++ hdr.dta_keyval.key[23:16] ++ hdr.dta_keyval.key[31:24], eg_md.redundancy_entry_num});
			
			//Bound the memory slot to memory size
			tbl_bound_slot.apply();
			//eg_md.destination_memory_slot = eg_md.destination_memory_slot % eg_md.collector_num_storage_slots;
			
			//Convert memory slot into address offset (multiply by payload size in bytes (8, i.e., bitshift 3 left))
			eg_md.memory_write_offset = (memory_address_t)(eg_md.destination_memory_slot);
			eg_md.memory_write_offset = eg_md.memory_write_offset*KEYWRITE_RDMA_PAYLOAD_SIZE; //Update the factor to equal payload size
			
		}
		
	}
}

control ControlPostcarder_cache(inout headers hdr, inout egress_metadata_t eg_md, inout postcarder_data_t md_result)(bit<32> checksum_seed, hop_num_t cached_hop)
{
	CRCPolynomial<bit<32>>(checksum_seed, true, false, false, 32w0xFFFFFFFF, 32w0xFFFFFFFF) poly1;                               
	Hash<postcarder_data_t>(HashAlgorithm_t.CUSTOM, poly1) hash_flowID_checksum;
	
	Register<postcarder_data_t, postcarder_cache_index_t>(POSTCARDER_CACHE_SIZE,0) reg_cache;
	/*RegisterAction<postcarder_data_t, postcarder_cache_index_t, bit<32>>(reg_cache) cache_write = {
		void apply(inout postcarder_data_t stored, out postcarder_data_t output)
		{
			stored = md_result; //Write into the cache
			output = 0; //We don't care about the output
		}
	};*/
	RegisterAction<postcarder_data_t, postcarder_cache_index_t, bit<32>>(reg_cache) cache_replace = {
		void apply(inout postcarder_data_t stored, out postcarder_data_t output)
		{
			output = stored; //Output the old value (used in case it's a cache collision to evict old postcards)
			stored = md_result; //Write into the cache
		}
	};
	RegisterAction<postcarder_data_t, postcarder_cache_index_t, bit<32>>(reg_cache) cache_extract = {
		void apply(inout postcarder_data_t stored, out postcarder_data_t output)
		{
			output = stored; //We want to extract this value, without writing new into the cache
			stored = 0; //reset the cache
		}
	};
	
	apply
	{
		//Store the input in md_result. This will be replaced in the end
		//slot = data XOR h(flowID)
		md_result = hdr.dta_postcarder.data ^ hash_flowID_checksum.get({hdr.dta_postcarder.key});
		
		//Encode the value, if this is the correct cache for the hop being reported
		if( hdr.dta_postcarder.hopNum == cached_hop ) //This is the correct slot for this packet
		{
			
			if( eg_md.postcarder_ready_for_compile == 1 ) //We want the cache reset afterwards. md_result will simply retain its calculated value
			{
				cache_extract.execute(eg_md.postcarder_cache_index); //Reset the cache
				//md_result = eg_md.postcarder_towrite; //We want to output the calculated value that WOULD have been stored in the cache
			}
			else //Just write into the cache (either it's a normal write (ignored output), or a collision (and the output will be used)
			{
				md_result = cache_replace.execute(eg_md.postcarder_cache_index);
			}
		}
		else if( eg_md.postcarder_ready_for_compile == 1 || eg_md.postcarder_collision == 1 ) //Extract other entries as well if we should compile a write
		{
			md_result = cache_extract.execute(eg_md.postcarder_cache_index);
		}
		
	}
}

control ControlPreparePostcarder(inout headers hdr, inout egress_metadata_t eg_md)
{
	Register<bit<32>, postcarder_cache_index_t>(POSTCARDER_CACHE_SIZE,0) reg_cache_flowid;
	RegisterAction<bit<32>, postcarder_cache_index_t, bit<32>>(reg_cache_flowid) flowid_verify = {
		void apply(inout bit<32> stored, out bit<32> output)
		{
			//Output 0 if there is no collision, otherwise output the old key (if there is a collision)
			if(stored == hdr.dta_postcarder.key)
				output = 0;
			else
				output = stored;
				
			stored = hdr.dta_postcarder.key; //Replace the flowID every time
		}
	};
	
	Register<bit<8>, postcarder_cache_index_t>(POSTCARDER_CACHE_SIZE,0) reg_cache_counter;
	RegisterAction<bit<8>, postcarder_cache_index_t, bit<8>>(reg_cache_counter) cache_counter_increment = {
		void apply(inout bit<8> stored, out bit<8> output)
		{
			stored = stored + 1;
			output = stored;
		}
	};
	RegisterAction<bit<8>, postcarder_cache_index_t, bit<8>>(reg_cache_counter) cache_counter_reset = {
		void apply(inout bit<8> stored, out bit<8> output)
		{
			stored = 1;
			output = 1;
		}
	};
	
	ControlPostcarder_cache(0x1e12a700, 1) cache_hop1;
	ControlPostcarder_cache(0x65b96595, 2) cache_hop2;
	ControlPostcarder_cache(0x49cf878b, 3) cache_hop3;
	ControlPostcarder_cache(0x36518f0d, 4) cache_hop4;
	ControlPostcarder_cache(0x7a40a908, 5) cache_hop5;
	
	//TODO: make one of these use a custom polynomial
	Hash<postcarder_cache_index_t>(HashAlgorithm_t.CRC32) hash_cache_index;
	Hash<memory_slot_t>(HashAlgorithm_t.CRC32) hash_memory_slot;
	
	
	/*
	 * Identical logic as KeyVal slot bounding.
	 * TODO: merge logic across primitives
	 */
	action bound_memory_slot(memory_slot_t mask)
	{
		eg_md.destination_memory_slot = eg_md.destination_memory_slot & mask;
	}
	table tbl_bound_slot
	{
		key = {
			eg_md.collector_num_storage_slots: exact;
		}
		actions = {
			bound_memory_slot;
		}
		const entries = {
			2: 				bound_memory_slot(0x00000001);
			4: 				bound_memory_slot(0x00000003);
			8: 				bound_memory_slot(0x00000007);
			16: 			bound_memory_slot(0x0000000f);
			32: 			bound_memory_slot(0x0000001f);
			64: 			bound_memory_slot(0x0000003f);
			128: 			bound_memory_slot(0x0000007f);
			256: 			bound_memory_slot(0x000000ff);
			512: 			bound_memory_slot(0x000001ff);
			1024: 			bound_memory_slot(0x000003ff);
			2048: 			bound_memory_slot(0x000007ff);
			4096: 			bound_memory_slot(0x00000fff);
			8192: 			bound_memory_slot(0x00001fff);
			16384: 			bound_memory_slot(0x00003fff);
			32768: 			bound_memory_slot(0x00007fff);
			65536: 			bound_memory_slot(0x0000ffff);
			131072: 		bound_memory_slot(0x0001ffff);
			262144: 		bound_memory_slot(0x0003ffff);
			524288: 		bound_memory_slot(0x0007ffff);
			1048576: 		bound_memory_slot(0x000fffff);
			2097152: 		bound_memory_slot(0x001fffff);
			4194304: 		bound_memory_slot(0x003fffff);
			8388608: 		bound_memory_slot(0x007fffff);
			16777216: 		bound_memory_slot(0x00ffffff);
			33554432: 		bound_memory_slot(0x01ffffff);
			67108864: 		bound_memory_slot(0x03ffffff);
			134217728: 		bound_memory_slot(0x07ffffff);
			268435456: 		bound_memory_slot(0x0fffffff);
			536870912: 		bound_memory_slot(0x1fffffff);
			1073741824: 	bound_memory_slot(0x3fffffff);
			2147483648: 	bound_memory_slot(0x7fffffff);
			//4294967296: 	bound_memory_slot(0xffffffff); //does not fit in 32-bit
			
		}
		size=64;
	}
	
	
	action set_server_info(remote_key_t remote_key, queue_pair_t queue_pair, memory_address_t memory_address_start, memory_slot_t collector_num_storage_slots, qp_reg_index_t qp_reg_index)
	{
		eg_md.remote_key = remote_key;
		eg_md.queue_pair = queue_pair;
		eg_md.memory_address_start = memory_address_start;
		eg_md.collector_num_storage_slots = collector_num_storage_slots;
		eg_md.qp_reg_index = qp_reg_index;
	}
	table tbl_getCollectorMetadataFromIP
	{
		key = {
			hdr.ipv4.dstAddr: exact;
		}
		actions = {
			set_server_info;
		}
		size = MAX_SUPPORTED_QPS;
	}
	
	
	//TODOs:
	//Craft actual RDMA using postcards
	//Encode value (hashing)
	//Calculate destination address (and bound it!)
	//Populate server info table
	apply
	{
		eg_md.postcarder_cache_index = hash_cache_index.get({hdr.dta_postcarder.key});
		eg_md.rdma_payload_length = 20; //20B, data*5 (for a full 5-hop path)
		
		tbl_getCollectorMetadataFromIP.apply();
		
		//Check if there is a flowID collision in the cache
		eg_md.stored_flowID = flowid_verify.execute(eg_md.postcarder_cache_index);
		if( eg_md.stored_flowID != 0 ) //A collision
		{
			eg_md.postcarder_collision = 1; //Signal that there was a collision
			cache_counter_reset.execute(eg_md.postcarder_cache_index); //Reset the postcard counter
			eg_md.cache_counter = 0;
		}
		else
		{
			//Increment the cache counter
			eg_md.cache_counter = cache_counter_increment.execute(eg_md.postcarder_cache_index);
			eg_md.postcarder_collision = 0;
		}
		
		//Currently hard-coded cache counter to 5 postcards
		//TODO: make this stated in postcards themselves?
		//Shorter ones will report when they get evicted
		if(eg_md.cache_counter == 5)
		{
			eg_md.postcarder_ready_for_compile = 1; //Signal that we got all postcards
		}
		else
			eg_md.postcarder_ready_for_compile = 0; //Signal that we don't yet have all postcards
		
		//Either extract cached entries, or write into one of these (depending on postcarder_ready_for_compile) 
		cache_hop1.apply(hdr, eg_md, eg_md.postcarder_data1);
		cache_hop2.apply(hdr, eg_md, eg_md.postcarder_data2);
		cache_hop3.apply(hdr, eg_md, eg_md.postcarder_data3);
		cache_hop4.apply(hdr, eg_md, eg_md.postcarder_data4);
		cache_hop5.apply(hdr, eg_md, eg_md.postcarder_data5);
		
		
		//Calculate destination memory slot
		eg_md.destination_memory_slot = hash_memory_slot.get({hdr.dta_postcarder.key});
		
		//Bound the memory slot to memory size
		tbl_bound_slot.apply();
		
		//Convert memory slot into address offset (multiply by payload size in bytes (8, i.e., bitshift 3 left))
		eg_md.memory_write_offset = (memory_address_t)(eg_md.destination_memory_slot);
		eg_md.memory_write_offset = eg_md.memory_write_offset*32; //We need to multiply by power of 2, so we need to add 12B padding to the 20B payloads. Slots are therefore not compact in DRAM
		
		
		//If we should craft RDMA
		if( eg_md.postcarder_ready_for_compile == 1 || eg_md.postcarder_collision == 1 )
		{
			//Compile RDMA payload
			hdr.rdma_payload_postcarder.setValid();
			hdr.rdma_payload_postcarder.data1 = eg_md.postcarder_data1;
			hdr.rdma_payload_postcarder.data2 = eg_md.postcarder_data2;
			hdr.rdma_payload_postcarder.data3 = eg_md.postcarder_data3;
			hdr.rdma_payload_postcarder.data4 = eg_md.postcarder_data4;
			hdr.rdma_payload_postcarder.data5 = eg_md.postcarder_data5;
			eg_md.prevent_rdma_generation = 0;
		}
		else
		{
			eg_md.prevent_rdma_generation = 1; //Signal that we should NOT generate RDMA
		}
	}
}



control ControlCraftRDMA(inout headers hdr, inout egress_metadata_t eg_md)
{
	//allocating 32-bit register array to hold 24-bit PSNs
	Register<bit<32>, qp_reg_index_t>(MAX_SUPPORTED_QPS) reg_rdma_sequence_number;
	RegisterAction<psn_t, qp_reg_index_t, psn_t>(reg_rdma_sequence_number) get_psn = {
		void apply(inout psn_t stored_psn, out psn_t output)
		{
			output = stored_psn; //Output the non-incremented PSN
			stored_psn = stored_psn + 1; //Increment the PSN (should roll over)
		}
	};
	RegisterAction<psn_t, qp_reg_index_t, psn_t>(reg_rdma_sequence_number) set_psn = {
		void apply(inout psn_t stored_psn, out psn_t output)
		{
			stored_psn = eg_md.rdma_psn; //Resynchronize the PSN to the value retrieved by the ack
			output = stored_psn;
		}
	};
	
	action setEthernet()
	{
		hdr.ethernet.setValid();
		//hdr.ethernet.dstAddr = 0xb49691b3ace8; //Hard-coded
		
		//hdr.ethernet.srcAddr = 0xb49691b3ace8; //hard-coded coming from Intel
		hdr.ethernet.srcAddr = 0xb8cef6d21326;
		hdr.ethernet.dstAddr = 0xb8cef6d212c7; //hard coded for bluefield
	}
	
	action setIP()
	{
		//TODO: finish filling out all fields with correct values
		hdr.ipv4.setValid();
		hdr.ipv4.ihl = 5;
		//DSCP field shall be set to the value in the Traffic Class component of the RDMA Address Vector associated with the packet.
		//hdr.ipv4.ecn = 0;
		hdr.ipv4.identification = 11381; //From random dumped packet
		//hdr.ipv4.ecn = 0b10; //According to dumped roce traffic
		hdr.ipv4.ecn = 0b00;
		//Total Length field shall be set to the length of the IPv4 packet in bytes including the IPv4 header and up to and including the ICRC.
		//hdr.ipv4.totalLen = 60+RDMA_PAYLOAD_SIZE_BYTES; //20+8+12+16+4 (+4 bytes payload) = 64
		hdr.ipv4.totalLen = ( \
			hdr.icrc.minSizeInBytes() + \
			hdr.reth.minSizeInBytes() + \
			hdr.bth.minSizeInBytes() + \
			hdr.udp.minSizeInBytes() + \
			hdr.ipv4.minSizeInBytes());
		//eg_md.rdma_payload_length + \
		
		hdr.ipv4.flags = 0b010;
		hdr.ipv4.fragOffset = 0;
		//Time to Live field shall be setto the value in the Hop Limit component of the RDMA Address Vector associated with the packet.
		hdr.ipv4.protocol = 0x11; //Set IPv4 proto to UDP
		//hdr.ipv4.dstAddr = eg_md.collector_ip; //Set address to collector address //dstAddr should already point to the collector (set at reporting switch)
		//hdr.ipv4.srcAddr = 0x0a000005; //Coming from random IP 10.0.0.5
		//hdr.ipv4.srcAddr = 0x7f000001; //127.0.0.1
		hdr.ipv4.srcAddr = 0x0a000065; //10.0.0.101
		//hdr.ipv4.srcAddr = 0x0a00003d; //10.0.0.61
	}
	
	action setUDP()
	{
		//TODO: set the length value correctly
		hdr.udp.setValid();
		hdr.udp.srcPort = 10000; //Same as in initialization script
		hdr.udp.dstPort = ROCEV2_UDP_PORT;
		//The Length field in the UDP header of RoCEv2 packets shall be set to the number of bytes counting from the beginning of the UDP header up to and including the 4 bytes of the ICRC
		//hdr.udp.length = 40+RDMA_PAYLOAD_SIZE_BYTES; //8 + 12+16+4+4
		hdr.udp.length = ( \
			hdr.icrc.minSizeInBytes() + \
			hdr.reth.minSizeInBytes() + \
			hdr.bth.minSizeInBytes() + \
			hdr.udp.minSizeInBytes());
		//eg_md.rdma_payload_length + \
		hdr.udp.checksum = 0; //UDP checksum SHOULD be 0
	}
	
	action setInfiniband_BTH()
	{
		//Infiniband Specification: https://cw.infinibandta.org/document/dl/7158 (page 239)
		//RoCE brief example: https://community.mellanox.com/s/article/rocev2-cnp-packet-format-example
		
		//TODO: fill the infiniband header fields
		hdr.bth.setValid();
		hdr.bth.opcode = 0x0a; //RDMA WRITE Only (is this correct operation?)
		hdr.bth.solicitedEvent = 0;
		hdr.bth.migReq = 1; //originally 0, set to 1 according to cloned packet
		hdr.bth.padCount = 0; //Set this depending of how many padded bytes at end of payload. (PL sent as multiple of 4 bytes)
		hdr.bth.transportHeaderVersion = 0; //Verify that this one is correct
		hdr.bth.partitionKey = 0xffff; //Identifies the partition that the desitnation QP or EE Context is a member (everyone always just uses 0xffff)
		hdr.bth.fRes = 0;
		hdr.bth.bRes = 0;
		hdr.bth.reserved1 = 0;
		hdr.bth.destinationQP = eg_md.queue_pair; //Specifies the destnation queue pair (QP) identifier
		hdr.bth.ackRequest = 0; //Do we want an ACK? (default 0)
		hdr.bth.reserved2 = 0;
		//hdr.bth.packetSequenceNumber = eg_md.rdma_psn;
	}
	
	action setInfiniband_RETH()
	{
		//Infiniband Specification: https://cw.infinibandta.org/document/dl/7158 (page 239)
		//RoCE brief example: https://community.mellanox.com/s/article/rocev2-cnp-packet-format-example
		
		hdr.reth.setValid();
		
		hdr.reth.virtualAddress = eg_md.memory_address_start + eg_md.memory_write_offset; //This is default. Possibly an issue in addition of 64b
		//Split addition into two steps. Unsure about order here. Can either handle overflow/carried bit?
		//hdr.reth.virtualAddress[63:32] = eg_md.memory_address_start[63:32] + eg_md.memory_write_offset[63:32];
		//hdr.reth.virtualAddress[31:0] = eg_md.memory_address_start[31:0] + eg_md.memory_write_offset[31:0];
		//eg_md.destination_memory_address_1 = eg_md.memory_address_start[63:32] + eg_md.memory_write_offset[63:32];
		//eg_md.destination_memory_address_2 = eg_md.memory_address_start[31:0] + eg_md.memory_write_offset[31:0];
		//hdr.reth.virtualAddress[63:32] = eg_md.destination_memory_address_1;
		//hdr.reth.virtualAddress[31:0] = eg_md.destination_memory_address_2;
		//hdr.reth.virtualAddress = eg_md.destination_memory_address_1 ++ eg_md.destination_memory_address_2;
		
		//TODO: change from cast to only modify LSB (saving staging cost)
		hdr.reth.dmaLength = (bit<32>)eg_md.rdma_payload_length; //Length, in bytes, of DMA operation. I guess size of memory to write? Payload size?
	}
	
	//TODO: Add AETH generation support
	action setInfiniband_AETH()
	{
		hdr.atomic_eth.setValid();
		
		hdr.atomic_eth.virtualAddress = eg_md.memory_address_start + eg_md.memory_write_offset;
		hdr.atomic_eth.rKey = eg_md.remote_key;
		
		hdr.atomic_eth.data = hdr.dta_keyincrement.counter;
		//bit<64> data;
		//#bit<64> compare;
	}

	
	apply
	{
		//TODO: calculate the PSN index! And make sure that the correct one gets resynchronized
		//eg_md.rdma_psn = (bit<24>)hdr.ipv4.srcAddr; //Debugging
		
		//eg_md.rdma_psn = get_psn.execute(hdr.ipv4.dstAddr); //Retrieve and update the RDMA PSN for this server (based on destination address)
		setEthernet();
		@stage(2)
		{
		if( hdr.dta_base.isValid() ) //Transform the DTA into RDMA
		{
		
			//Craft headers for RoCEv2
			setIP();
			hdr.ipv4.totalLen = hdr.ipv4.totalLen+eg_md.rdma_payload_length; //This made the action too big to fit single stage
			setUDP();
			hdr.udp.length = hdr.udp.length+eg_md.rdma_payload_length; //same as IP, too big for single stage
			setInfiniband_BTH();
			
			hdr.bth.packetSequenceNumber = get_psn.execute(eg_md.qp_reg_index); //Retrieve and update the RDMA PSN for this QP
			
			if( hdr.dta_keyincrement.isValid() ) //KeyIncrement uses Fetch&Add (i.e., AETH)
			{
				hdr.bth.opcode = 0b00010100; //Code for Fetch&Add
				setInfiniband_AETH();
			}
			else//Others use Write (i.e., RETH)
			{
				setInfiniband_RETH();
				//This field was incorrectly flagged as tagalong by the compiler, so moved here to prevent that
				hdr.reth.rKey = eg_md.remote_key;
			}
			
			
			
			//setInfiniband_payload();
			
			hdr.icrc.setValid();
			
		}
		else if(eg_md.is_congestion_ack == 1) //This packet should resync the PSN counter
		{
			eg_md.rdma_psn = hdr.bth.packetSequenceNumber; //This is the value that we will reset the PSN to
			set_psn.execute(eg_md.qp_reg_index);
			
		}
		}
		//Disable DTA headers
		hdr.dta_base.setInvalid();
		hdr.dta_keyval.setInvalid();
		hdr.dta_keyincrement.setInvalid();
		hdr.dta_append.setInvalid();
		hdr.dta_postcarder.setInvalid();
	}
}




control SwitchEgress(inout headers hdr, inout egress_metadata_t eg_md, in egress_intrinsic_metadata_t eg_intr_md, in egress_intrinsic_metadata_from_parser_t eg_intr_from_prsr, inout egress_intrinsic_metadata_for_deparser_t eg_intr_md_for_dprsr, inout egress_intrinsic_metadata_for_output_port_t eg_intr_md_for_oport)
{
	Hash<telemetry_key_checksum_t>(HashAlgorithm_t.CRC32) hash_telemetry_key_checksum;
	
	ControlRDMARatelimit() RDMARatelimit;
	ControlPrepareKeyWrite() PrepareKeyWrite;
	ControlPrepareAppend() PrepareAppend;
	ControlPreparePostcarder() PreparePostcarder;
	ControlCraftRDMA() CraftRDMA;
	
	
	apply
	{
		//Detect if this is a congestion ACK from the server
		if(hdr.bth.opcode == 17 && hdr.ipv4.srcAddr == 0x0a000033) //IP is hard-coded for now
			eg_md.is_congestion_ack = 1;
		else
		{
			eg_md.is_congestion_ack = 0;
			eg_md.queue_pair = 0;
		}
		
		eg_md.egress_port = eg_intr_md.egress_port; //This is needed for RDMA rate limiting later
		
		if(hdr.dta_base.isValid()) //If this is a DTA operation
		{
			if( hdr.dta_base.opcode == DTA_OPCODE_KEYWRITE || hdr.dta_base.opcode == DTA_OPCODE_KEYINCREMENT ) //Key-value primitives
			{
				//Calculate the key checksum (with fixed endianness to speed up querying)
				//eg_md.telemetry_key_checksum = hash_telemetry_key_checksum.get({hdr.dta_keywrite.key});
				eg_md.telemetry_key_checksum = hash_telemetry_key_checksum.get({hdr.dta_keyval.key[7:0] ++ hdr.dta_keyval.key[15:8] ++ hdr.dta_keyval.key[23:16] ++ hdr.dta_keyval.key[31:24]});
				PrepareKeyWrite.apply(hdr, eg_md); //Handle DTA KeyWrite
			}
			else if( hdr.dta_base.opcode == DTA_OPCODE_APPEND ) //Append
			{
				PrepareAppend.apply(hdr, eg_md);
			}
			else if( hdr.dta_base.opcode == DTA_OPCODE_POSTCARDER ) //Postcarder
			{
				PreparePostcarder.apply(hdr, eg_md);
			}
		}
		
		//for ACK parsing, add hdr.bth.isValid() here (but make sure that this does not drop ALL rdma packets!)
		if( hdr.dta_base.isValid() || eg_md.is_congestion_ack == 1 ) //DTA packets and congestion ACKs should both enter here
		{
			RDMARatelimit.apply(hdr, eg_md);
			
			//Handle RDMA generation
			if( eg_md.prevent_rdma_generation == 0 ) //If RDMA generation can go ahead (actual generation, or PSN resync goes here)
				CraftRDMA.apply(hdr, eg_md);
			else //DTA traffic that should not generate RDMA shall be dropped here
				eg_intr_md_for_dprsr.drop_ctl = 1; //Drop the packet in deparser
		}
		
		
		if( eg_md.is_congestion_ack == 1 ) //This is a congestion ack, and was used to resync the PSN. Now it can be dropped (no need to send back to RDMA NIC)
			eg_intr_md_for_dprsr.drop_ctl = 1;
		
		eg_md.debug = (debug_t)eg_md.redundancy_entry_num; //This is required, or the compiler throws a random error
		//eg_md.debug = (debug_t)eg_intr_md.egress_rid_first;
		//eg_md.debug = (debug_t)eg_intr_md.egress_rid_first;
		
		//This should never trigger. The compiler fails unless I keep debug from being optimized away...
		if( eg_md.debug == 1010 )
			hdr.ipv4.srcAddr = (bit<32>)eg_md.debug;
	}
} 

control SwitchEgressDeparser(packet_out pkt, inout headers hdr, in egress_metadata_t eg_md, in egress_intrinsic_metadata_for_deparser_t eg_dprsr_md)
{
	Checksum() ipv4_checksum;
	//Checksum<bit<32>>() icrc_checksum;
	apply
	{
		//Update IPv4 checksum
		hdr.ipv4.hdrChecksum = ipv4_checksum.update(
			{hdr.ipv4.version,
			 hdr.ipv4.ihl,
			 hdr.ipv4.dscp,
			 hdr.ipv4.ecn,
			 hdr.ipv4.totalLen,
			 hdr.ipv4.identification,
			 hdr.ipv4.flags,
			 hdr.ipv4.fragOffset,
			 hdr.ipv4.ttl,
			 hdr.ipv4.protocol,
			 hdr.ipv4.srcAddr,
			 hdr.ipv4.dstAddr});
			 
		pkt.emit(hdr.ethernet);
		pkt.emit(hdr.ipv4);
		pkt.emit(hdr.udp);
		//pkt.emit(hdr.dta_base);
		//pkt.emit(hdr.dta_keywrite);
		pkt.emit(hdr.bth);
		pkt.emit(hdr.reth);
		pkt.emit(hdr.atomic_eth);
		pkt.emit(hdr.rdma_payload_append);
		pkt.emit(hdr.rdma_payload_postcarder);
		pkt.emit(hdr.rdma_payload_keyval);
		pkt.emit(hdr.keywrite_data); //Send along the DTA keywrite data payload (if it is set valid)
		pkt.emit(hdr.icrc);
	}
}


Pipeline(SwitchIngressParser(),
	SwitchIngress(),
	SwitchIngressDeparser(),
	SwitchEgressParser(),
	SwitchEgress(),
	SwitchEgressDeparser()
) pipe;

Switch(pipe) main;
