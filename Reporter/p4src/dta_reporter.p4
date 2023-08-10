/*
 * 
 * P4_16 for Tofino ASIC
 * Written by Jonatan Langlet for Direct Telemetry Access
 * Reporter pipeline
 * 
 */
#include <core.p4>
#include <tna.p4>

#define ETHERTYPE_IPV4 0x0800
#define ETHERTYPE_PITCHER 0x1337

#define CHECKSUM_CACHE_REGISTER_SIZE 65536 //Make sure this fits into telemetry_checksum_cache_index_t

#define DTA_PORT_NUMBER 40040

typedef bit<32> ipv4_address_t;

typedef bit<32> debug_t;
typedef bit<16> random_t;
typedef bit<16> telemetry_checksum_t;
typedef bit<16> telemetry_checksum_cache_index_t; //Make sure this is log(CHECKSUM_CACHE_REGISTER_SIZE)
typedef bit<32> telemetry_data_t;
typedef bit<8> collector_hash_t; //Ensure the lookup table is populated with 2^collector_hash_t entries
typedef bit<32> telemetry_key_t;

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

header dta_base_h
{
	bit<8> opcode;
	bit<1> immediate;
	bit<7> reserved;
	//bit<16> collectorID; //Do we need this field? Or maybe instead just use the IP?
}

header dta_keywrite_static_h
{
	bit<8> redundancyLevel;
	telemetry_key_t key;
	telemetry_data_t data;
}


header mirror_h
{
	pkt_type_t pkt_type;
	telemetry_key_t telemetry_key;
	telemetry_data_t telemetry_data;
}

header mirror_bridged_metadata_h
{
	pkt_type_t pkt_type;
	telemetry_key_t telemetry_key;
	telemetry_data_t telemetry_data;
}

struct headers
{
	mirror_bridged_metadata_h bridged_md;
	ethernet_h ethernet;
	ipv4_h ipv4;
	udp_h udp;
	dta_base_h dta_base;
	dta_keywrite_static_h dta_keywrite;
}

struct debug_digest_ingress_t
{
	random_t random;
	debug_t debug;
}

struct debug_digest_egress_t
{
	debug_t debug;
}

struct ingress_metadata_t
{
	debug_t debug; //Used for debug data (included in digest)
	random_t random;
	
	bit<1> send_debug_data;
	bit<1> generate_report;
	bit<1> detected_change; //If a change was detected
	
	pkt_type_t pkt_type;
	MirrorId_t mirror_session;
	
	telemetry_checksum_t telemetry_checksum;
	telemetry_data_t telemetry_data;
	telemetry_key_t telemetry_key;
	telemetry_checksum_cache_index_t telemetry_checksum_cache_index;
	telemetry_checksum_t checksum_to_insert_into_cache;
	telemetry_checksum_t last_telemetry_checksum_cache_element;
}

struct egress_metadata_t
{
	bit<1> is_report_packet;
	debug_t debug;
	
	telemetry_key_t telemetry_key;
	telemetry_data_t telemetry_data;
	
	collector_hash_t collector_hash;
	ipv4_address_t collector_ip;
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
		transition accept;
	}
}

control ControlProbabilisticReporting(inout headers hdr, inout ingress_metadata_t ig_md, inout ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md)
{
	Random<random_t>() rnd;
	
	action flag_report_generation()
	{
		ig_md.generate_report = 1;
		
		//Prepare for mirroring
		ig_intr_dprsr_md.mirror_type = MIRROR_TYPE_I2E; //Mirror I2E
		ig_md.pkt_type = PKT_TYPE_MIRROR;
		
		//Set mirror session
		ig_md.mirror_session = 1;
		
		ig_md.debug = 1234;
	}
	table tbl_probabilistic_reporting
	{
		key = {
			ig_md.random: range;
		}
		actions = {
			flag_report_generation;
			@defaultonly NoAction;
		}
		const default_action = NoAction;
		const entries = {
			//(0 .. 65535):  flag_report_generation(); //Always generate a report, regardless of random value
			(0 .. 1000):  flag_report_generation();
		}
		size=16;
	}
	
	apply
	{
		ig_md.debug = 1;
		
		ig_md.random = rnd.get();
		if( ig_md.detected_change == 1) //Detected changes always trigger a new report
		{
			flag_report_generation();
		}
		else
		{
			tbl_probabilistic_reporting.apply();
		}
		
	}
}

/*
 * 3-level hash-table LRU with telemetry data checksums, to detect changes to recent data
 * Assuming ig_md.checksum_to_insert_into_cache is populated
 * Also that ig_md.telemetry_checksum_cache_index is calculated
 * Will overwrite ig_md.last_telemetry_checksum_cache_element
 */
control ControlChecksumCacheLevel(inout ingress_metadata_t ig_md)
{
	Register<telemetry_checksum_t, telemetry_checksum_cache_index_t>(CHECKSUM_CACHE_REGISTER_SIZE,0) reg_checksum_cache;
	RegisterAction<telemetry_checksum_t, telemetry_checksum_cache_index_t, telemetry_checksum_t>(reg_checksum_cache) process_cache = {
		void apply(inout telemetry_checksum_t stored_checksum, out telemetry_checksum_t output)
		{
			output = stored_checksum; //Return back the old stored checksum
			stored_checksum = ig_md.checksum_to_insert_into_cache; //Insert the value from the prior cache level
		}
	};
	
	apply
	{
		ig_md.last_telemetry_checksum_cache_element = process_cache.execute(ig_md.telemetry_checksum_cache_index);
		
		//If found checksum in cache
		if( ig_md.last_telemetry_checksum_cache_element == ig_md.telemetry_checksum )
			ig_md.detected_change = 0;
	}
}

control ControlChangeDetection(inout headers hdr, inout ingress_metadata_t ig_md)
{
	Hash<telemetry_checksum_cache_index_t>(HashAlgorithm_t.CRC32) hash_cache_index;
	Hash<telemetry_checksum_t>(HashAlgorithm_t.CRC16) hash_telemetry_checksum;
	
	ControlChecksumCacheLevel() checksumCacheLevel1;
	ControlChecksumCacheLevel() checksumCacheLevel2;
	ControlChecksumCacheLevel() checksumCacheLevel3;
	
	
	apply
	{
		ig_md.detected_change = 1; //Default to 1 (will be overwritten if the checksum is found in a cache level)
		
		ig_md.telemetry_checksum = hash_telemetry_checksum.get({ig_md.telemetry_data});
		ig_md.telemetry_checksum_cache_index = hash_cache_index.get({hdr.ipv4.srcAddr,hdr.ipv4.dstAddr});
		
		
		ig_md.checksum_to_insert_into_cache = ig_md.telemetry_checksum; //Prepare checksum to add to cache
		checksumCacheLevel1.apply(ig_md); //Process cache level 1
		
		//If the checksum from last level was replaced, move old down one level (1->2)
		if( ig_md.last_telemetry_checksum_cache_element != ig_md.checksum_to_insert_into_cache )
		{
			ig_md.checksum_to_insert_into_cache = ig_md.last_telemetry_checksum_cache_element;
			checksumCacheLevel2.apply(ig_md);
		}
		
		//If the checksum from last level was replaced, move old down one level (2->3)
		if( ig_md.last_telemetry_checksum_cache_element != ig_md.checksum_to_insert_into_cache && ig_md.detected_change == 1 )
		{
			ig_md.checksum_to_insert_into_cache = ig_md.last_telemetry_checksum_cache_element;
			checksumCacheLevel3.apply(ig_md);
		}
		
	}
}

/*
 * This block is processing the INT packet in the sink (probabilistic flagging to generate RDMA)
 */
control ControlSink(inout headers hdr, inout ingress_metadata_t ig_md, inout ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md)
{
	ControlProbabilisticReporting() probabilisticReporting;
	ControlChangeDetection() changeDetection;
	
	apply
	{
		changeDetection.apply(hdr, ig_md);
		probabilisticReporting.apply(hdr, ig_md, ig_intr_dprsr_md);
	}
}

/*
 * Handles full Pitcher ingress functionality
 */
control ControlPitcher(inout headers hdr, inout ingress_metadata_t ig_md, in ingress_intrinsic_metadata_t ig_intr_md, in ingress_intrinsic_metadata_from_parser_t ig_intr_prsr_md, inout ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md, inout ingress_intrinsic_metadata_for_tm_t ig_intr_tm_md)
{
	ControlSink() Sink;
	
	apply
	{
		//This is our local measurement and key that we want to report
		//ig_md.telemetry_data = (telemetry_data_t)ig_intr_md.ingress_port;
		ig_md.telemetry_data = (telemetry_data_t)hdr.ipv4.identification;
		ig_md.telemetry_key = hdr.ipv4.srcAddr;
		
		//Do sink functionality (e.g., report preparation)
		Sink.apply(hdr, ig_md, ig_intr_dprsr_md);
	}
}

control SwitchIngress(inout headers hdr, inout ingress_metadata_t ig_md, in ingress_intrinsic_metadata_t ig_intr_md, in ingress_intrinsic_metadata_from_parser_t ig_intr_prsr_md, inout ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md, inout ingress_intrinsic_metadata_for_tm_t ig_intr_tm_md)
{
	ControlPitcher() Pitcher;
	
	action forward(PortId_t port)
	{
		ig_intr_tm_md.ucast_egress_port = port; //Set egress port
		hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
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
			@defaultonly drop;
		}
		default_action = drop;
		size=1024;
	}
	
	apply
	{
		tbl_forward.apply();
		
		ig_md.debug = 0;
		
		Pitcher.apply(hdr, ig_md, ig_intr_md, ig_intr_prsr_md, ig_intr_dprsr_md, ig_intr_tm_md);
		
		//Prepare bridging metadata to egress
		hdr.bridged_md.setValid();
		hdr.bridged_md.pkt_type = PKT_TYPE_NORMAL; //Mirrors will overwrite this one
		
		ig_md.send_debug_data = 1;
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
				ig_md.random,
				ig_md.debug
			});
		}
		
		//Mirroring
		if (ig_intr_dprsr_md.mirror_type == MIRROR_TYPE_I2E)
		{
			//Emit mirror with mirror_h header appended.
			mirror.emit<mirror_h>(ig_md.mirror_session, {ig_md.pkt_type, ig_md.telemetry_key, ig_md.telemetry_data});
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
		
		eg_md.telemetry_key = mirror_md.telemetry_key;
		eg_md.telemetry_data = mirror_md.telemetry_data;
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
		transition accept;
	}
}

/*
 * This control block is processing the report packet (crafting DTA)
 */
control ControlReporting(inout headers hdr, inout egress_metadata_t eg_md)
{
	Hash<collector_hash_t>(HashAlgorithm_t.CRC8) hash_collector_hash;
	
	action setEthernet()
	{
		hdr.ethernet.setValid();
	}
	action setIP()
	{
		//TODO: finish filling out all fields with correct values
		hdr.ipv4.setValid();
		hdr.ipv4.ihl = 5;
		//DSCP field shall be set to the value in the Traffic Class component of the RDMA Address Vector associated with the packet.
		hdr.ipv4.ecn = 0;
		//Total Length field shall be set to the length of the IPv4 packet in bytes including the IPv4 header and up to and including the ICRC.
		hdr.ipv4.totalLen = 39; //20+8+12+16+4 (+4 bytes payload) = 64
		hdr.ipv4.flags = 0b010;
		hdr.ipv4.fragOffset = 0;
		//Time to Live field shall be setto the value in the Hop Limit component of the RDMA Address Vector associated with the packet.
		hdr.ipv4.protocol = 0x11; //Set IPv4 proto to UDP
		hdr.ipv4.dstAddr = eg_md.collector_ip; //Set address to collector address
	}
	action setUDP()
	{
		//TODO: set the length value correctly
		hdr.udp.setValid();
		hdr.udp.srcPort = 0xc0de;
		hdr.udp.dstPort = DTA_PORT_NUMBER;
		//The Length field in the UDP header of RoCEv2 packets shall be set to the number of bytes counting from the beginning of the UDP header up to and including the 4 bytes of the ICRC
		hdr.udp.length = 19; //8 + 12+16+4+4
		hdr.udp.checksum = 0; //UDP checksum SHOULD be 0
	}
	
	action setDTA_base()
	{
		hdr.dta_base.setValid();
		hdr.dta_base.opcode = 0x01; //Which operation to perform
		hdr.dta_base.immediate = 0; //Specify the Immediate flag in DTA
	}
	
	action setDTA_keywrite()
	{
		hdr.dta_keywrite.setValid();
		hdr.dta_keywrite.redundancyLevel = 2; //Set the level of redundancy for this data
		hdr.dta_keywrite.key = eg_md.telemetry_key;
		hdr.dta_keywrite.data = eg_md.telemetry_data;
	}
	
	
	action set_collector_info(ipv4_address_t collector_ip)
	{
		eg_md.collector_ip = collector_ip;
	}
	table tbl_hashToCollectorServer
	{
		key = {
			eg_md.collector_hash: exact;
		}
		actions = {
			set_collector_info;
		}
		size=512;
	}
	
	
	apply
	{
		setEthernet();
		
		//Calculate collector hash for this key
		eg_md.collector_hash = hash_collector_hash.get({eg_md.telemetry_key});
		
		//Look up server info from the calculated hash
		tbl_hashToCollectorServer.apply();
		
		//Craft DTA headers
		setIP();
		setUDP();
		setDTA_base();
		setDTA_keywrite();
	}
}

control SwitchEgress(inout headers hdr, inout egress_metadata_t eg_md, in egress_intrinsic_metadata_t eg_intr_md, in egress_intrinsic_metadata_from_parser_t eg_intr_from_prsr, inout egress_intrinsic_metadata_for_deparser_t eg_intr_md_for_dprsr, inout egress_intrinsic_metadata_for_output_port_t eg_intr_md_for_oport)
{
	ControlReporting() Reporting;
	
	apply
	{
		if(eg_md.is_report_packet == 1)
		{
			eg_md.debug = 1;
			Reporting.apply(hdr, eg_md);
		}
		else
		{
			eg_md.debug = 2;
		}
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
		pkt.emit(hdr.dta_base);
		pkt.emit(hdr.dta_keywrite);
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
