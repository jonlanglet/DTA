#!/usr/bin/env python3

#from scapy.all import send, IP, ICMP
from scapy.all import *
#from scapy.contrib import roce
import random
import sys
import struct
import time
import random
import binascii
import ipaddress


#dstMAC = "56:2B:95:DB:33:39"
#dstMAC = "b8:ce:f6:61:a0:f6"
#dstMAC = "ff:ff:ff:ff:ff:ff"
#dstMAC = "b8:ce:f6:61:9f:96" #host

#dstMAC = "b8:ce:f6:61:9f:96" #host13
dstMAC = "b8:ce:f6:61:9f:9a" #dpu13

srcIP = "11.11.11.1"
dstIP = "10.1.0.3"

#rocev2_port = 4791 #Default RoCEv2=4791
rocev2_port = 5000


class BTH(Packet):
	name = "BTH"
	fields_desc = [
		ByteField("opcode", 0),
		BitField("solicitedEvent", 0, 1),
		BitField("migReq", 0, 1),
		BitField("padCount", 0, 2),
		BitField("transportHeaderVersion", 0, 4),
		XShortField("partitionKey", 0),
		XByteField("reserved1", 0),
		ThreeBytesField("destinationQP", 0),
		BitField("ackRequest", 0, 1),
		BitField("reserved2", 0, 7),
		ThreeBytesField("packetSequenceNumber", 0)
	]

class RETH(Packet):
	name = "RETH"
	fields_desc = [
		BitField("virtualAddress", 0, 64),
		IntField("rKey", 0),
		IntField("dmaLength", 0)
	]

class iCRC(Packet):
	name = "iCRC"
	fields_desc = [
		IntField("iCRC", 0),
		
	]

#Make RDMA write packet with 32bit payload
packetSequenceNumber = 0
def makeRocev2Write(payload=0xdeadbeef, address=0x0):
	global packetSequenceNumber
	partitionKey = 0
	destinationQP = 0
	dmaLength = 32
	virtualAddress = address #Start of buffer
	rKey = 0 #Kinda like the password
	
	
	iCRC_checksum = 0 #TODO: calculate this? Or ignore?
	
	payload = struct.pack(">I", payload)
	#virtualAddress = struct.pack(">Q", virtualAddress)
	
	packetSequenceNumber = packetSequenceNumber + 1

	pkt = Ether(src="b8:ce:f6:61:a0:f2",dst=dstMAC)
	pkt = pkt/IP(src=srcIP,dst=dstIP,ihl=5,flags=0b010,proto=0x11)
	pkt = pkt/UDP(sport=0xc0de,dport=rocev2_port,chksum=0)
	pkt = pkt/BTH(opcode=0b01010,partitionKey=partitionKey,destinationQP=destinationQP, packetSequenceNumber=packetSequenceNumber) #WRITE-ONLY
	pkt = pkt/RETH(dmaLength=dmaLength,virtualAddress=virtualAddress,rKey=rKey)
	pkt = pkt/Raw(payload)
	pkt = pkt/iCRC(iCRC=iCRC_checksum)
	
	return pkt


def calc_iCRC(pkt):
	#pkt_icrc_mod = pkt.copy()
	
	print("Calculating iCRC on packet", pkt)
	
	print("version", pkt["IP"].version)
	print("ihl", pkt["IP"].ihl)
	
	#CRC part 1
	crc_part_1 = struct.pack("!Q", 0xffffffffffffffff)
	
	#CRC part 2
	tmp1 = (pkt["IP"].version<<4) + (pkt["IP"].ihl)
	print("tmp1: %i(0x%x)" %(tmp1, tmp1) )
	tmp2 = (pkt["IP"].flags<<3) + (pkt["IP"].frag)
	print("tmp2: %i(0x%x)" %(tmp2, tmp2) )
	print(pkt["IP"].len)
	crc_part_2 = struct.pack("!BBHH", tmp1, 0xff, pkt["IP"].len, tmp2 )
	
	#CRC part 3
	srcIP = int(ipaddress.ip_address(pkt["IP"].src))
	print("srcIP", srcIP)
	crc_part_3 = struct.pack("!BBHI", 0xff, pkt["IP"].proto, 0xffff, srcIP )
	
	#CRC part 4
	dstIP = int(ipaddress.ip_address(pkt["IP"].dst))
	print("dstIP", dstIP)
	crc_part_4 = struct.pack("!IHH", dstIP, pkt["UDP"].sport, pkt["UDP"].dport )
	
	#CRC part 5
	tmp3 = (pkt["BTH"].solicitedEvent<<4+2+1) + (pkt["BTH"].migReq<<4+2) + (pkt["BTH"].padCount<<4) + (pkt["BTH"].transportHeaderVersion)
	print(pkt["UDP"].len, 0xffff, pkt["BTH"].opcode, tmp3, pkt["BTH"].partitionKey)
	crc_part_5 = struct.pack("!HHBBH", pkt["UDP"].len, 0xffff, pkt["BTH"].opcode, tmp3, pkt["BTH"].partitionKey )
	
	#CRC part 6
	dqp_1_1B = pkt["BTH"].destinationQP>>16
	dqp_2_2B = pkt["BTH"].destinationQP&0xffff
	tmp4 = (pkt["BTH"].ackRequest<<7) + (pkt["BTH"].reserved2)
	psn_1_1B = pkt["BTH"].packetSequenceNumber>>16
	psn_2_2B = pkt["BTH"].packetSequenceNumber&0xffff
	crc_part_6 = struct.pack("!BBHBBH", 0xff, dqp_1_1B, dqp_2_2B, tmp4, psn_1_1B, psn_2_2B)
	print("crc_part_1", crc_part_1)
	print("crc_part_2", crc_part_2)
	print("crc_part_3", crc_part_3)
	print("crc_part_4", crc_part_4)
	print("crc_part_5", crc_part_5)
	print("crc_part_6", crc_part_6)
	
	
	crc_indata_full = crc_part_1+crc_part_2+crc_part_3+crc_part_4+crc_part_5+crc_part_6
	
	print("crc_indata_full", crc_indata_full)
	
	output = binascii.crc32( crc_indata_full )
	print("iCRC checksum: ", output)
	return output

#Make RDMA-send packet
def makeRocev2Send():
	global packetSequenceNumber
	partitionKey = 0
	destinationQP = 0
	rKey = 0x42069 #Kinda like the password
	
	
	packetSequenceNumber = packetSequenceNumber + 1

	
	pkt = Ether(src="b8:ce:f6:61:a0:f2",dst=dstMAC)
	pkt = pkt/IP(src=srcIP,dst=dstIP,ihl=5,flags=0b010,proto=0x11)
	pkt = pkt/UDP(sport=0xc0de,dport=rocev2_port,chksum=0)
	pkt = pkt/BTH(opcode=0b00100,partitionKey=partitionKey,destinationQP=destinationQP, packetSequenceNumber=packetSequenceNumber) #WRITE-ONLY: 0b01010, SEND-ONLY: 0b00100
	
	
	#Force some field updates...
	pkt["IP"].len = 44 #48?
	pkt["UDP"].len = 24
	
	iCRC_checksum = calc_iCRC(pkt)
	
	pkt = pkt/iCRC(iCRC=iCRC_checksum)
	
	pkt.show2()
	pkt.show2()
	
	return pkt


def makeIPPacket():
	pkt = Ether(src="b8:ce:f6:61:a0:f2",dst=dstMAC)
	pkt = pkt/IP(src=srcIP,dst=dstIP)
	return pkt


def makeUDPPacket():
	pkt = Ether(src="b8:ce:f6:61:a0:f2",dst=dstMAC)
	pkt = pkt/IP(src=srcIP,dst=dstIP)/UDP()
	return pkt




pkt = makeRocev2Send()
print("Sending packet", pkt)
sendp(pkt, iface="enp4s0f0")
wrpcap("rocev2_send_pkt.pcap",pkt)


'''

numFlows = 5
flowHashes = []
for flowID in range(numFlows):
	flowHash = random.randint(0,2**64-1)
	flowHashes.append(flowHash)
	
#Send traffic
flowID = 0
while True:
	flowID += 1
	if flowID >= numFlows:
		flowID = 0
	
	payload = flowID
	address = flowHashes[flowID]
	
	print("Transmitting telemetry data. Flow:%i, payload:%i, hash:%i" %(flowID, payload, address))
	
	pkt = makeRocev2Write(payload=payload, address=address)
	print("Sending packet", pkt)
	sendp(pkt, iface="enp4s0f0")
	
	time.sleep(0.5)
'''
