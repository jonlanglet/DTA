#This is the switch-local controller for the DTA translator
#Written by Jonatan Langlet for Direct Telemetry Access
import datetime
import ipaddress
import hashlib
import struct
import os
p4 = bfrt.dta_translator.pipe
mirror = bfrt.mirror
pre = bfrt.pre

logfile = "/home/jonatan/dta_translator.log"


#Add static forwarding rules according to our testbed topology
forwardingRules = [
("10.0.0.101", 64), #Tofino CPU 0
("10.0.0.102", 65), #Tofino CPU 1
("10.0.0.200", 8), #earl-03 E810-C (generator)
("10.0.0.51", 156) #earl-04 Bluefield (collector)
]

#Map collector destination IPs to egress ports (ensure mcRules exist for all these ports) (for KeyWrite and KeyIncrement)
collectorIPtoPorts = [
#("10.1.0.1", 65),
#("10.1.0.2", 65),
#("10.1.0.3", 12), #12
#("10.1.0.4", 65)
#("10.0.0.200", 12),
#("10.0.0.101", 64),
("10.0.0.51", 156),
#("10.0.0.51", 64), #Debug, ensuring multicasted RoCEv2 ends up at switch CPU
]

keywrite_slot_size_B = 8 #default 8 (4+4B)
#keywrite_slot_size_B = 32 #make sure this is the same as the pipeline

postcarder_slot_size_B = 32 #5x2B = 20B, +16 padding = 32B. We need this to be a power of 2 for P4 implementation

num_data_lists = 4 #Number of data lists

#Multicast rules, used to map egress port and redundancy to multicast group ID
mcRules = [
	{
	"mgid":1,
	"egressPort":8,
	"redundancy":1
	},
	{
	"mgid":2,
	"egressPort":8,
	"redundancy":2
	},
	{
	"mgid":3,
	"egressPort":8,
	"redundancy":3
	},
	{
	"mgid":4,
	"egressPort":8,
	"redundancy":4
	},
	{
	"mgid":5,
	"egressPort":64,
	"redundancy":1
	},
	{
	"mgid":6,
	"egressPort":64,
	"redundancy":2
	},
	{
	"mgid":7,
	"egressPort":64,
	"redundancy":3
	},
	{
	"mgid":8,
	"egressPort":64,
	"redundancy":4
	},
	{
	"mgid":9,
	"egressPort":156,
	"redundancy":1
	},
	{
	"mgid":10,
	"egressPort":156,
	"redundancy":2
	},
	{
	"mgid":11,
	"egressPort":156,
	"redundancy":3
	},
	{
	"mgid":12,
	"egressPort":156,
	"redundancy":4
	}
	]



def log(text):
	global logfile, datetime
	line = "%s \t DigProc: %s" %(str(datetime.datetime.now()), str(text))
	print(line)
	
	f = open(logfile, "a")
	f.write(line + "\n")
	f.close()


def digest_callback(dev_id, pipe_id, direction, parser_id, session, msg):
	global p4, log, Digest
	#smac = p4.Ingress.smac
	log("Received message from data plane!")
	for dig in msg:
		print(dig)
	
	return 0

def bindDigestCallback():
	global digest_callback, log, p4
	
	try:
		p4.SwitchIngressDeparser.debug_digest.callback_deregister()
	except:
		pass
	finally:
		log("Deregistering old callback function (if any)")

	#Register as callback for digests (bind to DMA?)
	log("Registering callback...")
	p4.SwitchIngressDeparser.debug_digest.callback_register(digest_callback)

	log("Bound callback to digest")


def insertForwardingRules():
	global p4, log, ipaddress, forwardingRules
	log("Inserting forwarding rules...")
	
	for dstAddr,egrPort in forwardingRules:
		dstIP = ipaddress.ip_address(dstAddr)
		log("%s->%i" %(dstIP, egrPort))
		p4.SwitchIngress.tbl_forward.add_with_forward(dstAddr=dstIP, port=egrPort)

def insertKeyWriteRules():
	global p4, log, ipaddress, collectorIPtoPorts, mcRules
	log("Inserting KeyWrite rules...")
	
	maxRedundancyLevel = 4
	
	for collectorIP,egrPort in collectorIPtoPorts:
		collectorIP_bin = ipaddress.ip_address(collectorIP)
		
		for redundancyLevel in range(1,maxRedundancyLevel+1):
			
			log("%s,%i,%i" %(collectorIP,egrPort,redundancyLevel))
			
			#Find the correct multicast group ID from the mcRules list
			rule = [ r for r in mcRules if r["redundancy"]==redundancyLevel and r["egressPort"]==egrPort ]
			log(rule[0])
			multicastGroupID = rule[0]["mgid"]
			
			#multicastGroupID = 1 #Static for now. Update to match created multicast groups
			
			log("Adding multiwrite rule %s,N=%i - %i" %(collectorIP,redundancyLevel,multicastGroupID))
			
			p4.SwitchIngress.ProcessDTAPacket.tbl_Prep_KeyWrite.add_with_prep_MultiWrite(dstAddr=collectorIP_bin, redundancyLevel=redundancyLevel, mcast_grp=multicastGroupID)



def getCollectorMetadata(port):
	global log, os
	

	metadata_dir = "/home/jonatan/projects/dta/translator/rdma_metadata/%i" %port
	
	log("Setting up a new RDMA connection from virtual client... port %i dir %s" %(port, metadata_dir))
	os.system("python3 /home/jonatan/projects/dta/translator/init_rdma_connection.py --port %i --dir %s" %(port, metadata_dir))
	
	log("Reading collector metadata from disk...")
	try:
		f = open("%s/tmp_qpnum"%metadata_dir, "r")
		queue_pair = int(f.read())
		f.close()
		
		f = open("%s/tmp_psn"%metadata_dir, "r")
		start_psn = int(f.read())
		f.close()
		
		f = open("%s/tmp_memaddr"%metadata_dir, "r")
		memory_start = int(f.read())
		f.close()
		
		f = open("%s/tmp_memlen"%metadata_dir, "r")
		memory_length = int(f.read())
		f.close()
		
		f = open("%s/tmp_rkey"%metadata_dir, "r")
		remote_key = int(f.read())
		f.close()
	except:
		log("   !!!   !!!   Failed to read RDMA metadata   !!!   !!!   ")
	
	log("Collector metadata read from disk!")

	return queue_pair, start_psn, memory_start, memory_length, remote_key

psn_reg_index = 0

def setupKeyvalConnection(port=1337):
	global p4, log, ipaddress, collectorIPtoPorts, getCollectorMetadata, psn_reg_index, keywrite_slot_size_B
	
	source_qp = port
	
	print("Setting up KeyVal connection...")
	#init RDMA connection to keyval store
	queue_pair,start_psn,memory_start,memory_length,remote_key = getCollectorMetadata(port)
	print("queue_pair", queue_pair)
	
	for dstAddr,_ in collectorIPtoPorts:
		dstIP = ipaddress.ip_address(dstAddr)
		
		collector_num_storage_slots = int(memory_length/keywrite_slot_size_B) #How many data slots are allocated in the collector? memory_length/(csum+data size in bytes)
		
		#Populate packet sequence number register
		p4.SwitchEgress.CraftRDMA.reg_rdma_sequence_number.mod(f1=start_psn, REGISTER_INDEX=psn_reg_index)
		
		log("Populating PSN-resynchronization lookup table for QP->regIndex mapping")
		p4.SwitchEgress.RDMARatelimit.tbl_get_qp_reg_num.add_with_set_qp_reg_num(queue_pair=source_qp, qp_reg_index=psn_reg_index)
		
		log("Inserting KeyWrite RDMA lookup rule for collector ip %s" %dstAddr)
		print("psn_reg_index", psn_reg_index)
		p4.SwitchEgress.PrepareKeyWrite.tbl_getCollectorMetadataFromIP.add_with_set_server_info(dstAddr=dstIP, remote_key=remote_key, queue_pair=queue_pair, memory_address_start=memory_start, collector_num_storage_slots=collector_num_storage_slots, qp_reg_index=psn_reg_index)
		
		psn_reg_index += 1

def setupDatalistConnection():
	global p4, log, getCollectorMetadata, psn_reg_index, num_data_lists
	
	#  This is where you specify how many dataLists to set up connections to, and populate ASIC with metadata of
	#  list of (listID,rdmaCMPort) tuples
	#lists = [(1,1338),(2,1339),(3,1340),(4,1341)] #4 lists
	#lists = [(1,1338),(2,1339),(3,1340)] #3 lists
	#lists = [(1,1338),(2,1339)] #2 lists
	#lists = [(1,1338)] #1 list
	listSlotSize=4 #list slot size in bytes (size of data)
	
	list_start_port = 1338
	
	#for listID,port in lists:
	for listID in range(num_data_lists):
		port = list_start_port+listID
		
		print("Setting up dataList connection to list %i port %i..." %(listID, port))
		queue_pair,start_psn,memory_start,memory_length,remote_key = getCollectorMetadata(port)
		
		source_qp = port
		
		#Populate packet sequence number register
		p4.SwitchEgress.CraftRDMA.reg_rdma_sequence_number.mod(f1=start_psn, REGISTER_INDEX=psn_reg_index)
		
		log("Populating PSN-resynchronization lookup table for QP->regIndex mapping")
		p4.SwitchEgress.RDMARatelimit.tbl_get_qp_reg_num.add_with_set_qp_reg_num(queue_pair=source_qp, qp_reg_index=psn_reg_index)
		
		collector_num_storage_slots = int(memory_length/listSlotSize) #How many data slots are allocated in the collector? memory_length/(data size in bytes)
		psn_reg_index = int(psn_reg_index)
		
		
		log("Inserting Append-to-List RDMA lookup rule for listID %i" %listID)
		print("psn_reg_index", psn_reg_index)
		print("collector_num_storage_slots", collector_num_storage_slots)
		
		
		p4.SwitchEgress.PrepareAppend.tbl_getCollectorMetadataFromListID_1.add_with_set_server_info_1(listID=listID, remote_key=remote_key, queue_pair=queue_pair, memory_address_start=memory_start)
		p4.SwitchEgress.PrepareAppend.tbl_getCollectorMetadataFromListID_2.add_with_set_server_info_2(listID=listID, collector_num_storage_slots=collector_num_storage_slots, qp_reg_index=psn_reg_index)
		psn_reg_index += 1


def setupPostcarderConnection(port=1336):
	global p4, log, ipaddress, collectorIPtoPorts, getCollectorMetadata, psn_reg_index, postcarder_slot_size_B
	
	source_qp = port
	
	print("Setting up Postcarder connection...")
	#init RDMA connection to keyval store
	queue_pair,start_psn,memory_start,memory_length,remote_key = getCollectorMetadata(port)
	print("queue_pair", queue_pair)
	
	for dstAddr,_ in collectorIPtoPorts:
		dstIP = ipaddress.ip_address(dstAddr)
		
		collector_num_storage_slots = int(memory_length/postcarder_slot_size_B) #How many data slots are allocated in the collector? memory_length/(slotsize in bytes = 32B)
		
		#Populate packet sequence number register
		p4.SwitchEgress.CraftRDMA.reg_rdma_sequence_number.mod(f1=start_psn, REGISTER_INDEX=psn_reg_index)
		
		log("Populating PSN-resynchronization lookup table for QP->regIndex mapping")
		p4.SwitchEgress.RDMARatelimit.tbl_get_qp_reg_num.add_with_set_qp_reg_num(queue_pair=source_qp, qp_reg_index=psn_reg_index)
		
		log("Inserting Postcarder RDMA lookup rule for collector ip %s" %dstAddr)
		print("psn_reg_index", psn_reg_index)
		p4.SwitchEgress.PreparePostcarder.tbl_getCollectorMetadataFromIP.add_with_set_server_info(dstAddr=dstIP, remote_key=remote_key, queue_pair=queue_pair, memory_address_start=memory_start, collector_num_storage_slots=collector_num_storage_slots, qp_reg_index=psn_reg_index)
		
		psn_reg_index += 1


def insertCollectorMetadataRules():
	global p4, log, ipaddress, collectorIPtoPorts, getCollectorMetadata, setupKeyvalConnection, setupDatalistConnection, setupPostcarderConnection
	log("Inserting RDMA metadata into ASIC...")
	
	setupPostcarderConnection()
	
	setupKeyvalConnection()
	
	setupDatalistConnection()
	

#NOTE: this might break ALL rules about multicasting. Very hacky
def configMulticasting():
	global p4, pre, log, mcRules
	log("Configuring mirroring sessions...")
	
	lastNodeID=0
	
	for mcastGroup in mcRules:
		mgid = mcastGroup["mgid"]
		egressPort = mcastGroup["egressPort"]
		redundancy = mcastGroup["redundancy"]
		log("Setting up multicast %i, egr:%i, redundancy:%i" %(mgid, egressPort, redundancy))
		
		nodeIDs = []
		log("Adding multicast nodes...")
		for i in range(redundancy):
			lastNodeID += 1
			log("Creating node %i" %lastNodeID)
			pre.node.add(DEV_PORT=[egressPort], MULTICAST_NODE_ID=lastNodeID)
			nodeIDs.append(lastNodeID)
		
		log("Creating the multicast group")
		pre.mgid.add(MGID=mgid, MULTICAST_NODE_ID=nodeIDs, MULTICAST_NODE_L1_XID=[0]*redundancy, MULTICAST_NODE_L1_XID_VALID=[False]*redundancy)
	

def configMirrorSessions():
	global mirror, log
	log("Configuring mirroring sessions...")
	
	#TODO: fix truncation length
	mirror.cfg.add_with_normal(sid=1, session_enable=True, ucast_egress_port=65, ucast_egress_port_valid=True, direction="BOTH", max_pkt_len=43) #Mirror header+Ethernet+IP
	
	
def populateTables():
	global p4, log, insertForwardingRules, insertKeyWriteRules, insertCollectorMetadataRules
	
	log("Populating the P4 tables...")
	
	insertForwardingRules()
	insertKeyWriteRules()
	insertCollectorMetadataRules()

log("Starting")

configMulticasting()
populateTables()
configMirrorSessions()
bindDigestCallback()

#log("Starting periodic injection of DTA write packet (keeping system alive)")
#os.system("watch \"sudo /home/sde/dta/translator/inject_dta.py keywrite --data 10000 --key 0 --redundancy 1\" &")

print("*** Now start period WRITE function manually")
print("*** Now start period WRITE function manually")



log("Bootstrap complete")
