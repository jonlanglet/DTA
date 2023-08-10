#include <iostream>
#include <string>
#include <unistd.h>
#include <iomanip>
#include <thread>

#include <rdma/rdma_cma.h>
#include <infiniband/verbs.h>
#include <sys/mman.h> //To force hugetables
#include <math.h>
#include <vector>

#include <boost/crc.hpp>  // for boost::crc_32_type

#include <chrono>

using namespace std;

struct dataListEntry
{
	uint32_t data;
};

struct keywriteEntry
{
	uint32_t checksum;
	uint32_t data;
	//uint32_t data2;
	//uint32_t data3;
	//uint32_t data4;
	//uint32_t data5;
	//uint32_t data6;
	//uint32_t data7;
	
	//uint64_t data;
	//uint32_t checksum;
	//uint32_t offset;
};

struct postcarderEntry
{
	uint32_t hop1_data;
	uint32_t hop2_data;
	uint32_t hop3_data;
	uint32_t hop4_data;
	uint32_t hop5_data;
	//The slots have to be sized to a power of 2 for the Translator implementation, so we add 12B padding
	uint32_t padding1;
	uint32_t padding2;
	uint32_t padding3;
};

struct appendEntry
{
	uint32_t data;
};


//Send RDMA metadata in this format between serv-cli
struct __attribute((packed)) rdma_buffer_attr 
{
	uint64_t address;
	uint32_t length;
	union stag
	{
		/* if we send, we call it local stags */
		uint32_t local_stag;
		/* if we receive, we call it remote stag */
		uint32_t remote_stag;
	}stag;
};

class RDMAService
{
	public:
		struct ibv_context* context;
		struct ibv_pd* protection_domain;
		struct ibv_cq* completion_queue;
		struct ibv_qp* queue_pair;
		struct ibv_mr* memory_region;
		struct rdma_event_channel *cm_channel;
		struct rdma_cm_id *listen_id;
		struct rdma_cm_id *cm_id; 
		struct sockaddr_in sin; 
		struct rdma_cm_event *event; 
		struct ibv_comp_channel *completion_channel; 
		struct ibv_mr* client_metadata_mr;
		int initial_psn;
		string name;
		int rdmaCMPort;
		bool isReady = false;
		
		
		void setupConnectionManager()
		{
			int ret;
			
			cout << "Creating event channel" << endl;
			cm_channel = rdma_create_event_channel();                            
			if (!cm_channel) 
				cerr << "Failed to set up connection manager!" << endl;
			
			cout << "Creating RDMA ID" << endl;
			ret = rdma_create_id(cm_channel,&listen_id, NULL, RDMA_PS_TCP);
			if(ret)
				cerr << "Failed to create RDMA ID! err: " << ret << endl;
			
			sin.sin_family = AF_INET;
			sin.sin_port = htons(rdmaCMPort);
			sin.sin_addr.s_addr = INADDR_ANY;
			
			cout << "Binding RDMA_CM to port " << rdmaCMPort << endl;
			ret = rdma_bind_addr(listen_id, (struct sockaddr   *) &sin);
			if(ret)
				cerr << "Failed to bind RDMA address! err: " << ret << endl;
			
			cout << "Listening for RDMA connections to " << name << endl;
			ret = rdma_listen(listen_id,  1);
			if(ret)
				cerr << "Failed to listen to RDMA! err: " << ret << endl;
			
			//Wait for a connection request
			do
			{
				cout << "Waiting for ConnectionManager event (incoming connection request) for " << name << "..." << endl;
				ret = rdma_get_cm_event(cm_channel, &event);
				if(ret)
					cerr << "Failed to get CM event! err: " << ret << endl;
				cout << "Event detected" << endl;
			}
			while(event->event != RDMA_CM_EVENT_CONNECT_REQUEST); //stay here until correct event
			
			cm_id = event->id;
			
			cout << "Sending back an ack" << endl;
			rdma_ack_cm_event(event);
		}
		
		
		void allocProtectionDomain()
		{
			cout << "Allocating a protection domain..." << endl;
			protection_domain = ibv_alloc_pd(cm_id->verbs);
			cout << "Protection domain: " << protection_domain << endl;
		}
		
		void createCompletionQueue(int cq_size)
		{
			cout << "Creating a completion channel" << endl;
			completion_channel = ibv_create_comp_channel(cm_id->verbs);
			cout << "Completion channel created at " << completion_channel << endl;
			
			cout << "Creating a completion queue of size " << cq_size << "..." << endl;
			completion_queue = ibv_create_cq(cm_id->verbs, cq_size, nullptr, completion_channel, 0);
			cout << "Completion queue created at " << completion_queue << endl;
		}
		
		
		//Create a queue pair
		void createQueuePair()
		{
			cout << "Creating a queue pair for '" << name << "'..." << endl;
			
			struct ibv_qp_init_attr qp_attr;
			int ret;
			
			memset(&qp_attr, 0, sizeof(qp_attr));
			
			
			qp_attr.cap.max_send_wr = 32; 
			qp_attr.cap.max_send_sge = 32; 
			qp_attr.cap.max_recv_wr = 32; 
			qp_attr.cap.max_recv_sge = 32; 
			
			qp_attr.send_cq = completion_queue; //these don't have to be the same
			qp_attr.recv_cq = completion_queue; 
			qp_attr.qp_type = IBV_QPT_RC; 
			//qp_attr.sq_sig_all = 1; //All send queues will be posted to completion queue?
			
			ret = rdma_create_qp(cm_id, protection_domain, &qp_attr);
			queue_pair = cm_id->qp;
			
			if(ret)
				cerr << "Failed to create a queue-pair! err: " << ret << endl;
			
			cout << "Queue pair created at " << queue_pair << endl;
		}
		
		void acceptClientConnection()
		{
			cout << "Accepting the client connection for '" << name << "'..." << endl;
			
			struct rdma_conn_param conn_param = { };
			
			int ret;
			
			cout << "ignoring the receive.." << endl;
			
			cout << "Accepting the connection" << endl;
			ret = rdma_accept(cm_id, &conn_param);
			if(ret)
				cerr << "Failed to accept RDMA connection! err: " << ret << endl;
			
			ret = rdma_get_cm_event(cm_channel, &event);
			if(ret)
				cerr << "Failed to get RDMA event! err: " << ret << endl;
			
			cout << "Sending back an ack" << endl;
			rdma_ack_cm_event(event);
		}
		
		void registerMemoryRegion(void* buffer, size_t size)
		{
			cout << "Registering memory region " << buffer << " of size " << size << "B for '" << name << "'..." << endl;
			
			memory_region = ibv_reg_mr(protection_domain, buffer, size, IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_REMOTE_ATOMIC);
			
			/* 
			//RDMA has to be recompiled with support of physical addresses first. might improve keywrite performance at large memories
			struct ibv_exp_reg_mr_in in = {0};
			int my_access_flags = IBV_ACCESS_LOCAL_WRITE |\
			IBV_ACCESS_REMOTE_READ |\
			IBV_ACCESS_REMOTE_WRITE |\
			IBV_ACCESS_REMOTE_ATOMIC |\
			IBV_EXP_ACCESS_PHYSICAL_ADDR;
			in.pd = protection_domain;
			in.addr = buffer;
			in.length = size;
			in.exp_access = my_access_flags;
			memory_region = ibv_exp_reg_mr(&in);
			*/
			
			cout << "Registered memory region at " << memory_region << endl;
		}
		
		int getRQPSN()
		{
			struct ibv_qp_attr attr;
			struct ibv_qp_init_attr init_attr;
			
			ibv_query_qp(queue_pair, &attr, IBV_QP_RQ_PSN, &init_attr);
			
			return attr.rq_psn;
		}
		
		void setInitialPSN()
		{
			int currentPSN = getRQPSN();
			cout << "Setting the initial PSN for '" << name << "' to the current value of " << currentPSN << endl;
			initial_psn = currentPSN;
		}
		
		//buf should be a pointer to the registered buffer we can use to transfer server metadata
		void shareServerMetadata()
		{
			struct ibv_sge sge;
			struct ibv_send_wr send_wr = { }; 
			struct ibv_send_wr *bad_send_wr; 
			int ret;
			
			cout << "Waiting to share server/storage metadata with client/translator" << endl;
			
			//Send 16 bytes from storage
			sge.addr = (uint64_t) memory_region->addr;
			sge.length = (uint32_t) 16; //
			sge.lkey = (uint32_t)memory_region->lkey; 
			
			cout << "Storing metadata in provided pre-mapped buffer..." << endl;
			
			//Store the metadata in the correct format in the provided (mapped) buffer
			*((uint32_t*)memory_region->addr) = (uint32_t)(((uint64_t)memory_region->addr)&0xffffffff);
			*((uint32_t*)memory_region->addr+1) = (uint32_t)(((uint64_t)memory_region->addr) >> 32);
			*((uint32_t*)memory_region->addr+2) = (uint32_t)memory_region->length;
			*((uint32_t*)memory_region->addr+3) = (uint32_t)memory_region->lkey;
			
			cout << "Advertising addr: " << sge.addr << " len: " << sge.length << " lkey: " << sge.lkey << endl;
			
			send_wr.opcode = IBV_WR_SEND; 
			send_wr.send_flags = IBV_SEND_SIGNALED; 
			send_wr.sg_list    = &sge;
			send_wr.num_sge = 1;
			
			cout << "Sending RDMA metadata to client" << endl;
			ret = ibv_post_send(cm_id->qp, &send_wr, &bad_send_wr);
			if(ret)
				cerr << "Failed to send metadata!" << endl;
			
			
			cout << "Sleeping a while to ensure the client received the metadata before resetting it" << endl;
			sleep(2);
			
			//Reset the borrowed buffer, to not leave garbage in storage
			*((uint32_t*)memory_region->addr) = (uint32_t)0;
			*((uint32_t*)memory_region->addr+1) = (uint32_t)0;
			*((uint32_t*)memory_region->addr+2) = (uint32_t)0;
			*((uint32_t*)memory_region->addr+3) = (uint32_t)0;
			*((uint32_t*)memory_region->addr+4) = (uint32_t)0;
			*((uint32_t*)memory_region->addr+5) = (uint32_t)0;
			*((uint32_t*)memory_region->addr+6) = (uint32_t)0;
			*((uint32_t*)memory_region->addr+7) = (uint32_t)0;
			
			//We now set the initial PSN
			setInitialPSN();
		}
		
		void printRDMAInfo()
		{
			int currentPSN = getRQPSN();
			
			cout << "Printing RDMA info for '" << name << "'..." << endl;
			cout << "Local QP number: " << queue_pair->qp_num << endl;
			cout << "lkey: " << memory_region->lkey << endl;
			cout << "rkey: " << memory_region->rkey << endl;
			cout << "rq_psn: " << currentPSN << " (diff " << currentPSN-initial_psn << " from initial PSN)" << endl;
		}
		
		bool pollCompletion()
		{
			struct ibv_wc wc;
			int result;

			//do
			//{
				// ibv_poll_cq returns the number of WCs that are newly completed,
				// If it is 0, it means no new work completion is received.
				// Here, the second argument specifies how many WCs the poll should check,
				// however, giving more than 1 incurs stack smashing detection with g++8 compilation.
				result = ibv_poll_cq(completion_queue, 1, &wc);
			//} while (result == 0);

			cout << "Polling completion queue returned " << result << endl;
			
			if(result >= 0 && wc.status == ibv_wc_status::IBV_WC_SUCCESS)
			{
				// success
				return true;
			}

			// You can identify which WR failed with wc.wr_id.
			printf("Poll failed with status %s (work request ID: %lu)\n", ibv_wc_status_str(wc.status), wc.wr_id);
			return false;
		}
		
		void getAsyncEvent()
		{
			struct ibv_async_event *event;
			
			cout << "Waiting for an async event" << endl;
			ibv_get_async_event(cm_id->verbs, event);
			
			cout << "Event type: " << event->event_type << endl;
		}
		
		void printCompletionQueue()
		{
			cout << "Polling completion queue" << endl;
			pollCompletion();
			
			//cout << "Async event" << endl;
			//getAsyncEvent();
		}
		
		void sendPSNReync()
		{
			int currentPSN = getRQPSN();
			cout << "Sending a packet to trigger PSN resync in the translator for '" << name << "'..." << endl;
			cout << "TODO" << endl;
		}
		
		//This should be called before initiating the storage (that is inheriting RDMA)
		void initiateRDMA()
		{
			cout << "Initiating RDMA service for " << name << endl;
			
			setupConnectionManager();
			
			allocProtectionDomain();
			
			createCompletionQueue(128);
			
			createQueuePair();
			
			acceptClientConnection();
		}
		
		void allocateStorage();
		void printStorage();
		void analStorage();
		void clearStorage();
		void initiate();
		
		
		//Constructor
		RDMAService(string init_name, int init_rdmaCMPort)
		{
			name = init_name;
			rdmaCMPort = init_rdmaCMPort;
			cout << "RDMA service constructor for " << name << endl;
		}
};

void* allocateHugepages(uint64_t size)
{
	uint64_t hugepage_size = 1<<30;
	uint64_t num_hugepages = ceil((double)size/(double)hugepage_size);
	uint64_t mmap_alloc_size = num_hugepages * hugepage_size;
	
	cout << "Allocating hugepages for buffer size " << size << ". This requires " << num_hugepages << " hugepages." << endl;
	
	void* p = mmap(NULL, mmap_alloc_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);
	
	cout << "Buffer allocated at address " << p << endl;
	
	return p;
}

class KeywriteStore : public RDMAService
{
	public:
		uint64_t num_entries;
		uint64_t buffer_size;
		struct keywriteEntry* storage;
		
		void allocateStorage()
		{
			buffer_size = num_entries*sizeof(struct keywriteEntry); //in bytes
			
			cout << "Allocating keywrite storage for '" << name << "'... Entries: " << num_entries << " size(B): " << buffer_size << endl;
			
			storage = (struct keywriteEntry*)allocateHugepages(buffer_size);
			
			cout << "keywrite buffer starts at address " << storage << endl;
		}
		
		void printStorage()
		{
			cout << "Printing storage of '" << name << "'..." << endl;
			
			int max_output = 256; //Prevent printing more entries than this
			int i;
			int numPerRow = 8;
			
			for(i = 0; i < num_entries; i++)
			{
				if( i > max_output )
				{
					cout << "Killing print, reached limit of " << max_output << " printed entries" << endl;
					break;
				}
				
				uint32_t checksum = ntohl(storage[i].checksum);
				uint32_t data = ntohl(storage[i].data);
				//uint32_t data2 = ntohl(storage[i].data2);
				//uint32_t data3 = ntohl(storage[i].data3);
				
				if( i%numPerRow==0 )
					cout << endl << i << ":\t";
				cout << "(";
				cout << std::setfill('0') << std::setw(10) << checksum;
				cout << ",";
				cout << std::setfill('0') << std::setw(10) << data;
				/*cout << ",";
				cout << std::setfill('0') << std::setw(10) << data2;
				cout << ",";
				cout << std::setfill('0') << std::setw(10) << data3;*/
				cout << ") ";
			}
		}
		
		//Query a key
		uint32_t query(uint32_t key, char redundancy)
		{
			char  buffer[5]; //This is the crc input
			char buffer_key[4];
			uint32_t slot; //this will be store calculated keyval slots
			boost::crc_32_type result;
			boost::crc_32_type result_csum;
			
			
			memcpy( buffer, &key, 4 ); //Copy key into this buffer (same for all redundancies)
			memcpy( buffer_key, &key, 4 );
			
			//Calculate concatenated checksum
			result_csum.process_bytes(buffer_key, 4);
			uint32_t checksum = result_csum.checksum();
			//cout << "We are expecting checksum " << checksum << endl;
			
			for(char n = 0; n < redundancy; n++) //Loop through all redundancies
			{
				buffer[4] = n; //The redundancy slot will differ
				
				//Calculate the index slot for this redundancy entry
				result.process_bytes(buffer, 5); 
				slot = result.checksum();
				//cout << "pure index-selecting checksum: " << slot << endl;
				
				slot %= num_entries; //modulo this into actual storage
				//cout << "Key " << key << " redundancy n=" << (int)n << " hashed to slot " << slot << endl;
				//cout << "Data in this slot: " << storage[slot].data << "csum: " << storage[slot].checksum << endl;
				
				//cout << endl;
				
				//If the checksum is correct, stop here and return an answer
				if( checksum == storage[slot].checksum )
					return storage[slot].data;
			}
			
			//If no answer was found, return back a 0 (assuming that 0 signals return-None)
			return 0;
		}
		
		//Query time breakdown
		uint32_t query_timeBreakdown(uint32_t key, char redundancy)
		{
			char  buffer[5]; //This is the crc input
			char buffer_key[4];
			uint32_t slot; //this will be store calculated keyval slots
			boost::crc_32_type result;
			boost::crc_32_type result_csum;
			
			using std::chrono::high_resolution_clock;
			using std::chrono::duration_cast;
			using std::chrono::duration;
			using std::chrono::milliseconds;
			
			duration<double, std::milli> ms_double;
			double duration_timestamping;
			double duration_entry;
			double duration_bufferAlloc;
			double duration_checksumCalc;
			double duration_allEntries;
			double duration_total;
			
			auto t_start = high_resolution_clock::now(); //start time
			auto t_timestampDelay = high_resolution_clock::now(); //Time to get a timestamp
			
			memcpy( buffer, &key, 4 ); //Copy key into this buffer (same for all redundancies)
			memcpy( buffer_key, &key, 4 );
			
			auto t_bufferAlloc = high_resolution_clock::now(); //start time
			
			//Calculate concatenated checksum
			result_csum.process_bytes(buffer_key, 4);
			uint32_t checksum = result_csum.checksum();
			//cout << "We are expecting checksum " << checksum << endl;
			
			auto t_checksumCalculated = high_resolution_clock::now();
			
			for(char n = 0; n < redundancy; n++) //Loop through all redundancies
			{
				auto t_entryStart = high_resolution_clock::now();
				
				buffer[4] = n; //The redundancy slot will differ
				
				//Calculate the index slot for this redundancy entry
				result.process_bytes(buffer, 5); 
				slot = result.checksum();
				//cout << "pure index-selecting checksum: " << slot << endl;
				
				slot %= num_entries; //modulo this into actual storage
				//cout << "Key " << key << " redundancy n=" << (int)n << " hashed to slot " << slot << endl;
				//cout << "Data in this slot: " << storage[slot].data << "csum: " << storage[slot].checksum << endl;
				
				//cout << endl;
				
				auto t_entryEnd = high_resolution_clock::now();
				ms_double = t_entryEnd - t_entryStart;
				duration_entry = ms_double.count()/1000;
				cout << "Retrieving this entry took " << duration_entry << " seconds" << endl;
				
				//If the checksum is correct, stop here and return an answer
				if( checksum == storage[slot].checksum )
					return storage[slot].data;
			}
			auto t_finished = high_resolution_clock::now();
			
			ms_double = t_timestampDelay - t_start;
			duration_timestamping = ms_double.count()/1000;
			ms_double = t_bufferAlloc - t_timestampDelay;
			duration_bufferAlloc = ms_double.count()/1000;
			ms_double = t_checksumCalculated - t_bufferAlloc;
			duration_checksumCalc = ms_double.count()/1000;
			ms_double = t_finished - t_checksumCalculated;
			duration_allEntries = ms_double.count()/1000;
			ms_double = t_finished - t_start;
			duration_total = ms_double.count()/1000;
			
			cout << "duration_timestamping: " << duration_timestamping << endl;
			cout << "duration_bufferAlloc: " << duration_bufferAlloc << endl;
			cout << "duration_checksumCalc: " << duration_checksumCalc << endl;
			cout << "duration_allEntries: " << duration_allEntries << endl;
			cout << "duration_total: " << duration_total << endl;
			
			//If no answer was found, return back a 0 (assuming that 0 signals return-None)
			return 0;
		}
		
		uint32_t benchmark_querying(uint64_t num_keys, int offset, int step, int redundancy)
		{
			uint32_t result; //This prevents optimizing away memory retrieval
			
			cout << name << " starts querying " << num_keys << " keys, offset " << offset << " every " << step << "..." << endl;
			
			for(uint64_t key = offset; key < num_keys; key+=step)
				result = query(key,redundancy); //query the key
				
			cout << name << " is done!" << endl;
			
			return result;
		}
		
		void benchmark_querying_multithread(int num_threads, uint64_t num_queries, int redundancy)
		{
			cout << "Benchmarking querying in " << name << " through " << num_threads << " threads." << endl;
			cout << "This will query a total of " << num_queries << " keys, shared between all threads" << endl;
			thread thread_queryers[num_threads];
			
			using std::chrono::high_resolution_clock;
			using std::chrono::duration_cast;
			using std::chrono::duration;
			using std::chrono::milliseconds;
			
			auto t1 = high_resolution_clock::now(); //start time
			
			//Starting the querying threads
			for(int i = 0; i < num_threads; i++)
				thread_queryers[i] = thread(&KeywriteStore::benchmark_querying, this, num_queries, i, num_threads, redundancy); //Start the querying thread
			
			//Waiting for all threads to finish
			for(int i = 0; i < num_threads; i++)
				thread_queryers[i].join();
				
			auto t2 = high_resolution_clock::now(); //end time
			
			cout << "All threads are now done!" << endl;
			
			duration<double, std::milli> ms_double = t2 - t1; //query duration
			
			double duration_s = ms_double.count()/1000;
			
			cout << "Having " << num_threads << " threads query " << num_queries << " keys total took " << duration_s << " seconds" << endl;
			cout << "This equal a query rate of " << num_queries/(duration_s*1000000*num_threads) << " million queries per second each, totalling " << num_queries/(duration_s*1000000) << " million queries per second!" << endl;
		}
		
		
		void analStorage()
		{
			cout << "Analyzing " << name << " storage... Total slots to iterage over: " << num_entries << endl;
			
			
			uint64_t numEmpty = 0; //The number of empty/unused memory slots
			for(uint64_t i = 0; i < num_entries; i++)
			{
				if(i%1000000==0)
					cout << "." << flush;
				if( storage[i].checksum==0 && storage[i].data==0 ) //If the slot is just zeroes, assume empty
					numEmpty++;
			}
			cout << endl;
			
			double loadFactor = (double)(num_entries-numEmpty)/(double)num_entries;
			
			cout << "Memory slots in use: " << num_entries-numEmpty << " / " << num_entries << endl;
			cout << "Load factor: " << loadFactor*100 << "%" << endl;
		}
		
		void clearStorage()
		{
			cout << "Clearing storage of '" << name << "'..." << endl;
			
			if( !storage )
			{
				cout << "Storage of " << name << " is not initialized! Skipping..." << endl;
				return;
			}
			
			int i;
			for(i = 0; i < num_entries; i++)
			{
				storage[i].checksum = 0;
				storage[i].data = 0;
			}
		}
		
		void initiate()
		{
			cout << "Initiating storage for " << name << endl;
			
			initiateRDMA();
			allocateStorage();
			registerMemoryRegion(storage, buffer_size);
			shareServerMetadata();
			
			isReady = true;
		}
		
		thread initiate_threaded()
		{
			thread t(&KeywriteStore::initiate, this);
			
			return t;
		}
		
		KeywriteStore(uint64_t init_num_entries, int rdmaPort, string init_name = "KeyWriteStore"): RDMAService(init_name, rdmaPort)
		{
			num_entries = init_num_entries;
			if(num_entries > 536870912)
			{
				cerr << "!!! Translator pipeline currently supports as most 536870912 entries! " << num_entries << " allocated" << endl;
			}
			cout << "Constructor for '" << name << "'..." << endl;
		}
};


class PostcarderStore : public RDMAService
{
	public:
		uint64_t num_entries;
		uint64_t buffer_size;
		struct postcarderEntry* storage;
		
		void allocateStorage()
		{
			buffer_size = num_entries*sizeof(struct postcarderEntry); //in bytes
			
			cout << "Allocating postcarder storage for '" << name << "'... Entries: " << num_entries << " size(B): " << buffer_size << endl;
			
			storage = (struct postcarderEntry*)allocateHugepages(buffer_size);
			
			cout << "Postcarder buffer starts at address " << storage << endl;
		}
		
		void printStorage()
		{
			cout << "Printing storage of '" << name << "'..." << endl;
			
			int max_output = 256; //Prevent printing more entries than this
			int i;
			int numPerRow = 4;
			
			for(i = 0; i < num_entries; i++)
			{
				if( i > max_output )
				{
					cout << "Killing print, reached limit of " << max_output << " printed entries" << endl;
					break;
				}
				
				uint32_t hop1_data = ntohl(storage[i].hop1_data);
				uint32_t hop2_data = ntohl(storage[i].hop2_data);
				uint32_t hop3_data = ntohl(storage[i].hop3_data);
				uint32_t hop4_data = ntohl(storage[i].hop4_data);
				uint32_t hop5_data = ntohl(storage[i].hop5_data);
				
				if( i%numPerRow==0 )
					cout << endl << i << ":\t";
				cout << "(";
				cout << std::setfill('0') << std::setw(10) << hop1_data;
				cout << ",";
				cout << std::setfill('0') << std::setw(10) << hop2_data;
				cout << ",";
				cout << std::setfill('0') << std::setw(10) << hop3_data;
				cout << ",";
				cout << std::setfill('0') << std::setw(10) << hop4_data;
				cout << ",";
				cout << std::setfill('0') << std::setw(10) << hop5_data;
				cout << ") ";
			}
		}
		
		void analStorage()
		{
			cout << "Analyzing " << name << " storage... Total slots to iterage over: " << num_entries << endl;
			
			
			uint64_t numEmpty = 0; //The number of empty/unused memory slots
			for(uint64_t i = 0; i < num_entries; i++)
			{
				if(i%1000000==0)
					cout << "." << flush;
				if( storage[i].hop1_data==0 && storage[i].hop2_data==0 && storage[i].hop3_data==0 && storage[i].hop4_data==0 && storage[i].hop5_data==0 ) //If the slot is just zeroes, assume empty
					numEmpty++;
			}
			cout << endl;
			
			double loadFactor = (double)(num_entries-numEmpty)/(double)num_entries;
			
			cout << "Memory slots in use: " << num_entries-numEmpty << " / " << num_entries << endl;
			cout << "Load factor: " << loadFactor*100 << "%" << endl;
		}
		
		void clearStorage()
		{
			cout << "Clearing storage of '" << name << "'..." << endl;
			
			if( !storage )
			{
				cout << "Storage of " << name << " is not initialized! Skipping..." << endl;
				return;
			}
			
			int i;
			for(i = 0; i < num_entries; i++)
			{
				storage[i].hop1_data = 0;
				storage[i].hop2_data = 0;
				storage[i].hop3_data = 0;
				storage[i].hop4_data = 0;
				storage[i].hop5_data = 0;
			}
		}
		
		void initiate()
		{
			cout << "Initiating storage for " << name << endl;
			
			initiateRDMA();
			allocateStorage();
			registerMemoryRegion(storage, buffer_size);
			shareServerMetadata();
			
			isReady = true;
		}
		
		thread initiate_threaded()
		{
			thread t(&PostcarderStore::initiate, this);
			
			return t;
		}
		
		PostcarderStore(uint64_t init_num_entries, int rdmaPort, string init_name = "PostcarderStore"): RDMAService(init_name, rdmaPort)
		{
			num_entries = init_num_entries;
			if(num_entries > 536870912)
			{
				cerr << "!!! Translator pipeline currently supports as most 536870912 entries! " << num_entries << " allocated" << endl;
			}
			cout << "Constructor for '" << name << "'..." << endl;
		}
};

class DataList : public RDMAService
{
	public:
		uint64_t num_entries;
		uint64_t buffer_size;
		struct dataListEntry* storage;
		uint64_t tail_pointer;
		
		void allocateStorage()
		{
			buffer_size = num_entries*sizeof(struct dataListEntry); //in bytes
			
			cout << "Allocating List storage for '" << name << "'... Entries: " << num_entries << " size(B): " << buffer_size << endl;
			//storage = new struct dataListEntry[num_entries]; //Allocate on stack (required for tons of lists where not enough hugepages)
			storage = (struct dataListEntry*)allocateHugepages(buffer_size); //This is default, allocating on hugepages
			cout << "List buffer starts at address " << storage << endl;
		}
		
		//Retrieve a value from the list
		uint32_t pull()
		{
			if(++tail_pointer >= num_entries)
				tail_pointer = 0;
				
			return storage[tail_pointer].data;
		}
		
		//Breaking down costs of pulling an entry from the list. This seems silly here :)
		uint32_t pull_timeBreakdown()
		{
			using std::chrono::high_resolution_clock;
			using std::chrono::duration_cast;
			using std::chrono::duration;
			using std::chrono::milliseconds;
			
			duration<double, std::milli> ms_double;
			double duration_headpointer_s;
			double duration_retrieval_s;
			uint32_t result;
			
			auto t1 = high_resolution_clock::now();
			
			if(++tail_pointer >= num_entries)
				tail_pointer = 0;
			
			auto t2 = high_resolution_clock::now();
			
			result = storage[tail_pointer].data;
			
			auto t3 = high_resolution_clock::now();
			
			ms_double = t2 - t1;
			duration_headpointer_s = ms_double.count()/1000;
			ms_double = t3 - t2;
			duration_retrieval_s = ms_double.count()/1000;
			
			cout << "Updating the head pointer took " << duration_headpointer_s << " seconds." << endl;
			cout << "Retrieval memory slot took " << duration_retrieval_s << " seconds." << endl;
			
			return result;
		}
		
		void printStorage()
		{
			cout << "Printing storage of '" << name << "'..." << endl;
			
			int max_output = 64; //Prevent printing more entries than this
			int i;
			int numPerRow = 16;
			for(i = 0; i < num_entries; i++)
			{
				if( i > max_output )
				{
					cout << "Killing print, reached limit of " << max_output << " printed entries" << endl;
					break;
				}
				if( i%numPerRow==0 )
					cout << endl << i << ":\t";
				cout << "(";
				cout << std::setfill('0') << std::setw(10) << storage[i].data;
				cout << ") ";
			}
			cout << endl;
		}
		
		void findDataGaps()
		{
			cout << "Finding data gaps in the list, where values are not sequential..." << endl;
			
			cout << "Following is a list of gaps in the append list (gapStart,gapEnd)" << endl;
			
			uint32_t lastValue = 0;
			uint64_t lastMissingIndex = 0;
			
			for(uint64_t i = 0; i < num_entries; i++)
			{
				uint32_t thisValue = storage[i].data;
				
				//Ignore empty slots
				if(thisValue == 0)
					continue;
				
				if( thisValue != lastValue+1 )
				{
					/*
					cout << "Non-sequential value found at index " << i << "!" << endl;
					cout << "Previous value: " << lastValue << ", this value: " << thisValue << ", diff: " << (thisValue-lastValue) << endl;
					cout << "The last skipped value was back at index " << lastMissingIndex << " which was " << (i-lastMissingIndex) << " slots ago" << endl;
					cout << endl;
					*/
					cout << "(" << lastValue << "," << thisValue << ")," << flush;
				}
				
				lastValue = storage[i].data;
			}
			cout << endl;
		}
		
		void findEmptySlots()
		{
			cout << "Finding data gaps in the list, where data was not written..." << endl;
			
			cout << "Following is a list of gaps in the append list (gapStart,gapEnd)" << endl;
			
			uint64_t lastEmptyIndex = 0;
			uint64_t lastWrittenIndex = 0;
			
			for(uint64_t i = 0; i < num_entries; i++)
			{
				uint32_t thisValue = storage[i].data;
				
				if(thisValue == 0) //This slot is empty
				{
					lastEmptyIndex = i;
					if(i == num_entries-1) //This is the last slot, and it was empty. Report a gap until the end
						cout << "(" << lastWrittenIndex << "," << i << ")," << flush;
				}
				else //This slot is not empty
				{
					if(lastEmptyIndex == i-1) //If we just got out of a gap
						cout << "(" << lastWrittenIndex << "," << i << ")," << flush;
						
					lastWrittenIndex = i;
				}
			}
			
			cout << endl;
		}
		
		void findListFullness()
		{
			cout << "Finding out how full the list is..." << endl;
			uint64_t numEmpty = 0; //The number of empty/unused memory slots
			for(uint64_t i = 0; i < num_entries; i++)
			{
				if(i%1000000==0)
					cout << "." << flush;
				if( storage[i].data==0 ) //If the slot is just zeroes, assume empty
					numEmpty++;
			}
			cout << endl;
			
			double loadFactor = (double)(num_entries-numEmpty)/(double)num_entries;
			
			cout << "Memory slots in use: " << num_entries-numEmpty << " / " << num_entries << endl;
			cout << "Load factor: " << loadFactor*100 << "%" << endl;
		}
		
		void analStorage()
		{
			cout << "Analyzing " << name << "... " << endl;
			
			findListFullness();
			//findDataGaps();
			//findEmptySlots();
			
		}
		
		void clearStorage()
		{
			cout << "Clearing storage of '" << name << "'..." << endl;
			int i;
			for(i = 0; i < num_entries; i++)
			{
				storage[i].data = 0;
			}
		}
		
		uint32_t benchmark_querying(uint64_t num_pulls)
		{
			uint32_t pulledData; //This prevents optimizing away memory retrieval
			
			cout << name << " starts pulling " << num_pulls << " list entries..." << endl;
			for(uint64_t i = 0; i < num_pulls; i++)
				pulledData = pull(); //pull one data entry
			cout << name << " is done!" << endl;
			
			return pulledData;
		}
		
		void initiate()
		{
			cout << "Initiating storage for " << name << endl;
			
			initiateRDMA();
			allocateStorage();
			registerMemoryRegion(storage, buffer_size);
			shareServerMetadata();
			clearStorage();
			isReady = true;
		}
		
		
		thread initiate_threaded()
		{
			thread t(&DataList::initiate, this);
			
			return t;
		}
		
		DataList(uint64_t init_num_entries, int rdmaPort, string init_name="DataList"): RDMAService(init_name, rdmaPort)
		{
			num_entries = init_num_entries;
			cout << "Constructor for '" << name << "'..." << endl;
			
			tail_pointer = num_entries; //This ensures that polling will start at 0
		}
};

int main()
{
	cout << "Starting collector service..." << endl;
	
	//They only support storage sizes powers of 2
	
	
	//Allocate storage services
	PostcarderStore postcarderStore(256, 1336); //256 is 8KiB
	
	KeywriteStore keywriteStore(256, 1337); //256 is 2KiB
	//KeywriteStore keywriteStore(8388608, 1337); //8388608 is 64MiB
	//KeywriteStore keywriteStore(16777216, 1337); //16777216 is 128MiB
	//KeywriteStore keywriteStore(33554432, 1337); //33554432 is 256MiB
	//KeywriteStore keywriteStore(67108864, 1337); //67108864 is 512MiB
	//KeywriteStore keywriteStore(134217728, 1337); //134217728 is 1GiB
	//KeywriteStore keywriteStore(268435456, 1337); //268435456: 2GiB
	//KeywriteStore keywriteStore(536870912, 1337); //536870912: 4GiB
	//KeywriteStore keywriteStore(1073741824, 1337); //1073741824: 8GiB
	//KeywriteStore keywriteStore(2147483648, 1337); //2147483648: 16GiB
	
	
	//DataList dataList(256, 1338); //256 is 1KiB
	//DataList dataList(16777216, 1338); //16777216 is 64MiB
	//DataList dataList(33554432, 1338); //67108864 is 128MiB
	//DataList dataList(67108864, 1338); //67108864 is 256MiB
	//DataList dataList(134217728, 1338); //134217728 is 512MiB
	//DataList dataList(268435456, 1338); //268435456 is 1GiB
	//DataList dataList(536870912, 1338); //536870912 is 2GiB
	//DataList dataList(1073741824, 1338); //1073741824 is 4GiB
	//DataList dataList(2147483648, 1338); //2147483648 is 8GiB
	//DataList dataList(4294967296, 1338); //4294967296 is 16GiB
	
	int num_lists = 4; //Number of lists
	int list_port_start = 1338;
	uint64_t slots_per_list = 256; //The size of the published lists, in number of slots 268435456
	
	//Create data lists
	DataList **dataLists;
	dataLists = new DataList*[num_lists];
	for(int i = 0; i < num_lists; i++)
	{
		cout << i << endl;
		*(dataLists+i) = new DataList(slots_per_list, list_port_start+i, "List"+to_string(i));
	}
	
	//Initiate the storages in separate threads	
	thread thread_keyvalue = keywriteStore.initiate_threaded();
	thread thread_datalists[num_lists];
	for(int i = 0; i < num_lists; i++)
		thread_datalists[i] = dataLists[i]->initiate_threaded(); //ignore the returned thread handler
	
	//Stay here indefinitely, keeping collector alive
	while(1)
	{
		cout << endl;
		
		cout << "Press ENTER to analyze storage. This MIGHT impact RDMA performance, so avoid during benchmarking!";
		cin.ignore();
		
		//Print info for all lists (APPEND)
		for(int i = 0; i < num_lists; i++)
		{
			if(dataLists[i]->isReady)
			{
				dataLists[i]->printRDMAInfo();
				dataLists[i]->printStorage();
				dataLists[i]->analStorage();
				//dataLists[i]->findEmptySlots(); //0 is used to get throughput
			}
			else
				cout << dataLists[i]->name << " is not ready yet, skipping. " << endl;
		}
		
		//Print some list info
		/*
		if(dataLists[num_lists-1]->isReady)
		{
			dataLists[0]->printRDMAInfo();
			dataLists[0]->printStorage();
			dataLists[0]->analStorage();
			dataLists[0]->findEmptySlots(); //0 is used to get throughput
			dataLists[1]->printRDMAInfo();
			dataLists[1]->printStorage();
			dataLists[1]->analStorage();
			dataLists[num_lists-1]->printRDMAInfo();
			dataLists[num_lists-1]->printStorage();
			dataLists[num_lists-1]->analStorage();
		}
		else
			cout << "All lists not yet ready" << endl;
		*/
		
		/*
		//Append querying benchmark. This under-estimates the speed due to startup costs being included
		if(dataLists[num_lists-1]->isReady)
		{
			uint64_t num_pulls;
			int num_lists_to_query;
			cout << "Will benchmark querying for all lists" << endl;
			cout << "Enter number of lists to query in parallel: ";
			cin >> num_lists_to_query;
			
			if(num_lists_to_query > num_lists)
			{
				cout << "TOO MANY LISTS!" << endl;
				continue; //skip
			}
			
			cout << "Enter number of pulls to do for each list: ";
			cin >> num_pulls;
			
			thread thread_queryers[num_lists];
			
			using std::chrono::high_resolution_clock;
			using std::chrono::duration_cast;
			using std::chrono::duration;
			using std::chrono::milliseconds;
			
			auto t1 = high_resolution_clock::now(); //start time
			
			//Start threads one-by-one
			for(int i = 0; i < num_lists_to_query; i++)
				thread_queryers[i] = thread(&DataList::benchmark_querying, dataLists[i], num_pulls); //Start the querying thread
			
			//wait here for all threads to complete (pulling done)
			for(int i = 0; i < num_lists_to_query; i++)
				thread_queryers[i].join();
			
			auto t2 = high_resolution_clock::now(); //end time
			
			cout << "All queryers are now done!" << endl;
			
			duration<double, std::milli> ms_double = t2 - t1; //query duration
			
			double duration_s = ms_double.count()/1000;
			
			cout << "Having " << num_lists_to_query << " lists pull " << num_pulls << " each took " << duration_s << " seconds" << endl;
			cout << "This equal a query rate of " << num_pulls/(duration_s*1000000) << " million reports each, totalling " << num_lists_to_query*num_pulls/(duration_s*1000000) << " million reports per second!" << endl;
			
			
			cout << "Breaking down list 0 pulling work..." << endl;
			dataLists[0]->pull_timeBreakdown();
		}
		*/
		
		if(keywriteStore.isReady)
		{
			keywriteStore.printRDMAInfo();
			keywriteStore.printStorage();
			keywriteStore.analStorage();
			cout << endl;
			
			
			
			cout << "Completion queue of keywrite..." << endl;
			keywriteStore.printCompletionQueue();
			cout << endl;
			
			/*
			cout << "Enter a key integer to query: " << endl;
			uint32_t key;
			cin >> key;
			cin.clear();
			cout << "Query result: " << keywriteStore.query(key, 4) << endl;
			cin.ignore();
			*/
			
			/*
			cout << "Number of incrementing keys to query: ";
			int num_queries;
			cin >> num_queries;
			for(uint32_t i = 0; i < num_queries; i++)
				keywriteStore.query(i, 2);
			cout << "Done" << endl;
			*/
			
			/* QUERY benchmark
			int num_threads;
			uint64_t num_queries;
			int redundancy;
			
			cout << "Enter number of threads that will query Key-Write: ";
			cin >> num_threads;
			cout << "Enter total number of queries to run: ";
			cin >> num_queries;
			cout << "Enter level of redundancy (N) to used during queries: ";
			cin >> redundancy;
			
			if(num_threads > 32)
			{
				cout << "Too many threads" << endl;
				continue;
			}
			
			keywriteStore.benchmark_querying_multithread(num_threads, num_queries, redundancy);
			
			cout << "Querying key 1 at chosen redundancy, and printing query processing breakdown" << endl;
			uint32_t result = keywriteStore.query_timeBreakdown(1, redundancy);
			cout << "res: " << result << endl;
			*/
		}
		else
			cout << keywriteStore.name << " is not yet ready. Please initiate a connection first" << endl;
	}
	
	cout << "Collector stopping" << endl;
	
	return 1;
}
