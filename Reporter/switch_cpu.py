import datetime
import ipaddress
import hashlib
import struct
import math
p4 = bfrt.dta_reporter.pipe
mirror = bfrt.mirror

logfile = "/home/sde/dta_reporter.log"


#Add static forwarding rules according to our testbed topology
forwardingRules = [
("10.0.0.101", 64), #Tofino CPU 0
("10.0.0.102", 65), #Tofino CPU 1
("10.0.0.200", 12), #earl-03 E810-C (Collector)
("10.0.0.51", 152) #earl-03 Bluefield
]

collectorHashBits = 8 #Ensure this matches collector_hash_t in p4
maxCollectorHashVal = 2**collectorHashBits

#List the collector server IPs. Algo will automatically map these across collector hash range
collectorServerIPs = [
"10.0.0.51"
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

def insertNewCollectorServer(collector_hash, collector_ip):
	global p4, log, ipaddress
	
	log("Inserting collector server. %i -> %s" %(collector_hash, collector_ip))
	
	collector_ip = ipaddress.ip_address(collector_ip)
	
	p4.SwitchEgress.Reporting.tbl_hashToCollectorServer.add_with_set_collector_info(collector_hash=collector_hash, collector_ip=collector_ip)
	
#Map collector hashes into collector server IPs
def insertCollectorServerLookups():
	global log, insertNewCollectorServer, maxCollectorHashVal, collectorServerIPs, math
	log("Inserting server mapping P4 rules...")
	
	numCollectors = len(collectorServerIPs)
	hashesPerCollector = math.ceil(maxCollectorHashVal/numCollectors)
	
	print("numCollectors", numCollectors)
	print("hashesPerCollector", hashesPerCollector)
	
	for collector_hash in range(maxCollectorHashVal):
		collectorIndexPointer = int(collector_hash/hashesPerCollector)
		
		collector_ip = collectorServerIPs[collectorIndexPointer] #Retrieve a collector IP from global list
		
		insertNewCollectorServer(collector_hash=collector_hash, collector_ip=collector_ip)
	
def configMirrorSessions():
	global mirror, log
	log("Configuring mirroring sessions...")
	
	#TODO: fix truncation length
	#mirror.cfg.add_with_normal(sid=1, session_enable=True, ucast_egress_port=65, ucast_egress_port_valid=True, direction="BOTH", max_pkt_len=34) #34: Ethernet+IP
	mirror.cfg.add_with_normal(sid=1, session_enable=True, ucast_egress_port=65, ucast_egress_port_valid=True, direction="BOTH", max_pkt_len=43) #Mirror header+Ethernet+IP
	
	
def populateTables():
	global p4, log, insertSwitchIDRules, insertForwardingRules, insertSinkDetectingRules, insertCollectorServerLookups
	
	log("Populating the P4 tables...")
	
	insertForwardingRules()
	insertCollectorServerLookups()

log("Starting")

populateTables()
configMirrorSessions()
bindDigestCallback()

log("Bootstrap complete")
