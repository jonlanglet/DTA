#!/usr/bin/env python3

#from scapy.all import send, IP, ICMP
from scapy.all import *
import random
import sys
import binascii
import struct
import argparse


parser = argparse.ArgumentParser(description='Initiate an RDMA connection with the collector, and write metadata to disk.')
parser.add_argument('--port', type=int, default=1337, help='The TCP port to the collector RDMA_CM')
parser.add_argument('--dir', type=str, default="/home/jonatan/rdma_metadata/", help='The directory where to store the RDMA connection metadata')
args = parser.parse_args()

class rocev2_bth(Packet):
	name = "BTH"
	fields_desc = [ 
		XByteField("opcode",	100),
		BitField("solicited",	0,		1),
		BitField("migreq", 		1,		1),
		BitField("padcount",	0,		2),
		BitField("version",		0,		4),
		XShortField("pkey",		0xffff),
		BitField("fecn",		0,		1),
		BitField("becn",		0,		1),
		BitField("resv6",		0,		6),
		BitField("destQP",		1,		24),
		BitField("ackreq",		0,		1),
		BitField("resv7",		0,		7),
		BitField("psn",			52,		24)
	]

class rocev2_deth(Packet):
	name = "DETH"
	fields_desc = [ 
		IntField("queueKey",	0x80010000),
		ByteField("reserved",	0x00),
		XBitField("sourceQP", 	0x000001,		24)
	]

class rocev2_mad(Packet):
	name = "MAD"
	fields_desc = [ 
		XIntField("part1",	0x01070203),
		XIntField("part2",	0x0),
		XIntField("part3",	0x00000006),
		XIntField("part4",	0x7c313d63),
		XIntField("part5",	0x00100000),
		XIntField("part6",	0x30000000),
	]

class rocev2_connectRequest(Packet):
	name = "connectRequest"
	fields_desc = [
		XIntField("lComID",	0x633d317c),
		XIntField("part2",	0x000015b3),
		XIntField("part3",	0x0),
		BitField("part4_0", 0x0106, 16),
		BitField("dstPort", 0x0539, 16), #default: 1337
		#XIntField("part4",	0x01060539),
		XIntField("part5",	0xb8cef603),
		XIntField("part6",	0x00d21326),
		XIntField("part7",	0x0),
		XIntField("part8",	0x0),
		#XIntField("part9",	0x0011b903),
		XIntField("sourceQP",	0x0011b903), #default: 0x0011b903
		XIntField("part10",	0x00000003),
		XIntField("part11",	0x000000b0),
		XIntField("part12",	0xe6fb20b3),
		XIntField("part13",	0xffff30f0),
		XIntField("part14",	0xffffffff),
		XIntField("part15",	0x0),
		XIntField("part16",	0x0),
		XIntField("part17",	0x0000ffff),
		XIntField("srcIP1",	0x0a000065), #10.0.0.101 (def 61, 0a:00:00:3d)
		XIntField("part19",	0x0),
		XIntField("part20",	0x0),
		XIntField("part21",	0x0000ffff),
		XIntField("dstIP1",	0x0a000033), #10.0.0.51
		XIntField("part23",	0x943e0007),
		XIntField("part24",	0x00400098),
		XIntField("part25",	0x0),
		XIntField("part26",	0x0),
		XIntField("part27",	0x0),
		XIntField("part28",	0x0),
		XIntField("part29",	0x0),
		XIntField("part30",	0x0),
		XIntField("part31",	0x0),
		XIntField("part32",	0x0),
		XIntField("part33",	0x0),
		XIntField("part34",	0x0),
		XIntField("part35",	0x0),
		XIntField("part36",	0x0040d079),
		XIntField("part37",	0x0),
		XIntField("part38",	0x0),
		XIntField("part39",	0x0),
		XIntField("srcIP2",	0x0a000065), #Source IP again
		XIntField("part41",	0x0),
		XIntField("part42",	0x0),
		XIntField("part43",	0x0),
		XIntField("dstIP2",	0x0a000033), #Destination Ip again
		XIntField("part45",	0x0),
		XIntField("part46",	0x0),
		XIntField("part47",	0x0),
		XIntField("part48",	0x0),
		XIntField("part49",	0x0),
		XIntField("part50",	0x0),
		XIntField("part51",	0x0),
		XIntField("part52",	0x0),
		XIntField("part53",	0x0),
		XIntField("part54",	0x0),
		XIntField("part55",	0x0),
		XIntField("part56",	0x0),
		XIntField("part57",	0x0),
		XIntField("part58",	0x0),
		
		
	]

class rocev2_readyToUse(Packet):
	name = "readyToUse"
	fields_desc = [
		XIntField("lComID",	0x633d317c), #same as last packet
		XIntField("rComID",	0x0), #0x1ff69dfd in dumped packet. Has to be according to ConnectReply
		XIntField("part3",	0x0),
		XIntField("part4",	0x0),
		XIntField("part5",	0x0),
		XIntField("part6",	0x0),
		XIntField("part7",	0x0),
		XIntField("part8",	0x0),
		XIntField("part9",	0x0),
		XIntField("part10",	0x0),
		XIntField("part11",	0x0),
		XIntField("part12",	0x0),
		XIntField("part13",	0x0),
		XIntField("part14",	0x0),
		XIntField("part15",	0x0),
		XIntField("part16",	0x0),
		XIntField("part17",	0x0),
		XIntField("part18",	0x0),
		XIntField("part19",	0x0),
		XIntField("part20",	0x0),
		XIntField("part21",	0x0),
		XIntField("part22",	0x0),
		XIntField("part23",	0x0),
		XIntField("part24",	0x0),
		XIntField("part25",	0x0),
		XIntField("part26",	0x0),
		XIntField("part27",	0x0),
		XIntField("part28",	0x0),
		XIntField("part29",	0x0),
		XIntField("part30",	0x0),
		XIntField("part31",	0x0),
		XIntField("part32",	0x0),
		XIntField("part33",	0x0),
		XIntField("part34",	0x0),
		XIntField("part35",	0x0),
		XIntField("part36",	0x0),
		XIntField("part37",	0x0),
		XIntField("part38",	0x0),
		XIntField("part39",	0x0),
		XIntField("part40",	0x0),
		XIntField("part41",	0x0),
		XIntField("part42",	0x0),
		XIntField("part43",	0x0),
		XIntField("part44",	0x0),
		XIntField("part45",	0x0),
		XIntField("part46",	0x0),
		XIntField("part47",	0x0),
		XIntField("part48",	0x0),
		XIntField("part49",	0x0),
		XIntField("part50",	0x0),
		XIntField("part51",	0x0),
		XIntField("part52",	0x0),
		XIntField("part53",	0x0),
		XIntField("part54",	0x0),
		XIntField("part55",	0x0),
		XIntField("part56",	0x0),
		XIntField("part57",	0x0),
		XIntField("part58",	0x0),
	]

class rocev2_aeth(Packet):
	name = "AETH"
	fields_desc = [ 
		ByteField("reserved",	0x00),
		XBitField("msgSeqNum",	0x00, 24),
	]

class rocev2_icrc(Packet):
	name = "iCRC"
	fields_desc = [ 
		XIntField("iCRC",	0)
	]


def craft_ConnectRequest():
	sport = 10000
	srcMac = "b8:ce:f6:d2:13:26"
	dstMac = "b8:ce:f6:d2:12:c7"
	pktID = 0x2c70 #stolen from cloned traffic
	psn = 100
	dport = int(args.port) #will also be the advertised source QP, to ensure consistent and unique
	#sport=dport
	#psn=dport
	#pktID=dport
	lComID=dport
	#sourceQP=dport<<16 #advertise the client QP to be equal to the collector port (just to ensure unique)
	sourceQP=dport<<8 #fix bitshift, should be correct now
	
	pkt = Ether(src=srcMac,dst=dstMac)\
	/IP(src="10.0.0.101",dst="10.0.0.51",id=pktID,flags="DF")\
	/UDP(dport=4791,sport=sport)\
	/rocev2_bth(psn=psn)\
	/rocev2_deth(sourceQP=dport)\
	/rocev2_mad()\
	/rocev2_connectRequest(dstPort=dport,sourceQP=sourceQP,lComID=lComID)\
	/rocev2_icrc()
	
	return pkt

def craft_ReadyToUse(rComID):
	sport = 10000
	srcMac = "b8:ce:f6:d2:13:26"
	dstMac = "b8:ce:f6:d2:12:c7"
	pktID = 0x2c70 #stolen from cloned traffic
	psn = 100
	dport = int(args.port) #will also be the advertised source QP, to ensure consistent and unique
	#sport=dport
	#psn=dport
	#pktID=dport
	lComID=dport
	
	pkt = Ether(src=srcMac,dst=dstMac)\
	/IP(src="10.0.0.101",dst="10.0.0.51",id=pktID,flags="DF")\
	/UDP(dport=4791,sport=sport)\
	/rocev2_bth(psn=psn)\
	/rocev2_deth(sourceQP=dport)\
	/rocev2_mad(part5=0x00140000)\
	/rocev2_readyToUse(rComID=rComID,lComID=lComID)\
	/rocev2_icrc()
	
	return pkt

def craft_ack(msgSeqNum,qpNum):
	sport = 10000
	srcMac = "b8:ce:f6:d2:13:26"
	dstMac = "b8:ce:f6:d2:12:c7"
	pktID = 0x2c70 #stolen from cloned traffic
	psn = 100
	dport = int(args.port) #will also be the advertised source QP, to ensure consistent and unique
	#sport=dport
	#psn=dport
	#pktID=dport
	
	pkt = Ether(src=srcMac,dst=dstMac)\
	/IP(src="10.0.0.101",dst="10.0.0.51",id=pktID,flags="DF")\
	/UDP(dport=4791,sport=sport)\
	/rocev2_bth(opcode=0x11,psn=psn,destQP=qpNum)\
	/rocev2_aeth(msgSeqNum=msgSeqNum)\
	/rocev2_icrc()
	
	return pkt

def process_connectReply(packet):
	#Manually extract the RoCEv2 header from the packet
	pkt_bytes = binascii.hexlify(bytes(packet[UDP].payload))
	bth_bytes = pkt_bytes[0:24] #BTH header size 12B (correct)
	deth_bytes = pkt_bytes[24:40] #DETH header size 8B (correct)
	mad_bytes = pkt_bytes[40:88] #MAD header size 23B (correct)
	CM_connectreply_bytes = pkt_bytes[88:552] #CM ConnectReply header size 231B (correct)
	icrc_bytes = pkt_bytes[552:560] #iCRC header size 4B (correct)
	
	print("bth_bytes", bth_bytes)
	print("deth_bytes", deth_bytes)
	print("mad_bytes", mad_bytes)
	print("CM_connectreply_bytes", CM_connectreply_bytes)
	print("icrc_bytes", icrc_bytes)
	
	
	#Extract essential values from the packet
	lComID_offset = 0
	lComID_size = 8
	lComID = int(CM_connectreply_bytes[lComID_offset:lComID_offset+lComID_size],16)
	
	qpNum_offset = 8+8+8
	qpNum_size = 6
	qpNum = int(CM_connectreply_bytes[qpNum_offset:qpNum_offset+qpNum_size],16)
	
	psn_offset = qpNum_offset+6+10
	psn_size = 6
	psn = int(CM_connectreply_bytes[psn_offset:psn_offset+psn_size],16)
	
	return lComID,qpNum,psn

def process_sendAllocatedBuffer(packet):
	print("Processing server metadata packet")
	
	#Manually extract the RoCEv2 header from the packet
	pkt_bytes = binascii.hexlify(bytes(packet[UDP].payload))
	bth_bytes = pkt_bytes[0:24] #BTH header size 12B (correct)
	payload_bytes = pkt_bytes[24:56] #payload size 16B (correct)
	icrc_bytes = pkt_bytes[56:64] #iCRC header size 4B (correct)
	
	print("pkt_bytes", pkt_bytes)
	print("bth_bytes", bth_bytes)
	print("payload_bytes", payload_bytes)
	print("icrc_bytes", icrc_bytes)
	
	#Fix address endianess and extract server-allocated memory buffer address
	addr1 = payload_bytes[0:2]
	addr2 = payload_bytes[2:4]
	addr3 = payload_bytes[4:6]
	addr4 = payload_bytes[6:8]
	addr5 = payload_bytes[8:10]
	addr6 = payload_bytes[10:12]
	addr7 = payload_bytes[12:14]
	addr8 = payload_bytes[14:16]
	memory_start = addr8+addr7+addr6+addr5+addr4+addr3+addr2+addr1
	print("memory_start:", hex(int(memory_start,16)))
	
	len1 = payload_bytes[16:18]
	len2 = payload_bytes[18:20]
	len3 = payload_bytes[20:22]
	len4 = payload_bytes[22:24]
	memory_length = len4+len3+len2+len1
	print("memory_length:", hex(int(memory_length,16)))
	
	rkey1 = payload_bytes[24:26]
	rkey2 = payload_bytes[26:28]
	rkey3 = payload_bytes[28:30]
	rkey4 = payload_bytes[30:32]
	remote_key = rkey4+rkey3+rkey2+rkey1
	print("remote_key:", hex(int(remote_key,16)))
	
	return int(memory_start,16), int(memory_length,16), int(remote_key,16)



num_processed_rocev2 = 0
qpNum = 0
psn = 0
memory_start = 0
memory_length = 0
remote_key = 0

def informOfMetadata():
	print("The QP number is: %i" %qpNum)
	print("The initial PSN is: %i" %psn)
	print("Memory start address in collector: %u" %memory_start)
	print("Memory length in collector: %u" %memory_length)
	print("The remote key is: %u" %remote_key)
	
	path = args.dir
	#create the path
	try:
		os.makedirs(path)
	except:
		pass
	
	print("Writing RDMA connection metadata to %s" %path)
	
	f = open("%s/tmp_qpnum"%path, "w")
	f.write(str(qpNum))
	f.close()
	
	f = open("%s/tmp_psn"%path, "w")
	f.write(str(psn))
	f.close()
	
	f = open("%s/tmp_memaddr"%path, "w")
	f.write(str(memory_start))
	f.close()
	
	f = open("%s/tmp_memlen"%path, "w")
	f.write(str(memory_length))
	f.close()
	
	f = open("%s/tmp_rkey"%path, "w")
	f.write(str(remote_key))
	f.close()

def process_rocev2(packet):
	global num_processed_rocev2,qpNum,psn,memory_start,remote_key,memory_length
	
	num_processed_rocev2 += 1
	print("num_processed_rocev2", num_processed_rocev2)
	
	print(binascii.hexlify(bytes(packet[UDP].payload)))
	
	#If this is the first rocev2 packet, must be ConnectReply
	if num_processed_rocev2 == 1:
		lComID,qpNum,psn = process_connectReply(packet)
		
		reply = craft_ReadyToUse(lComID)
		
		sendp(reply, iface="enp4s0f0")
	elif num_processed_rocev2 == 2:
		memory_start,memory_length,remote_key = process_sendAllocatedBuffer(packet)
		
		informOfMetadata()
		
		#Send back an ack, and we're done!
		pkt_ack = craft_ack(num_processed_rocev2,qpNum)
		sendp(pkt_ack, iface="enp4s0f0")
		
	else:
		print("Random roce packet. Ignoring")
		pkt_ack = craft_ack(num_processed_rocev2,qpNum)
		#sendp(pkt_ack, iface="enp4s0f0")
	
	print()


#Start sniffing for incoming RoCEv2 traffic
sniffer = AsyncSniffer(filter="inbound and udp", iface='enp4s0f0', prn=process_rocev2)

#Create a connection request packet
pkt = craft_ConnectRequest()


print("Starting sniffer...")
sniffer.start()

print("Waiting 1 sec before continuing")
time.sleep(1)

print("Sending packet", pkt)
sendp(pkt, iface="enp4s0f0")

print("Waiting 3 sec to allow setup to complete")
time.sleep(3)

sniffer.stop()
