#!/usr/bin/env python3

#from scapy.all import send, IP, ICMP
from scapy.all import *
import random
import sys
import binascii
import struct
import argparse
import time

parser = argparse.ArgumentParser(description='Inject a DTA Key-Write packet into the Tofino ASIC.')
parser.add_argument('operation',  type=str, nargs='+', choices=["keywrite", "append"], help='The DTA operation')
parser.add_argument('--data',  type=int, nargs='+', help='The telemetry data')
parser.add_argument('--key',  type=int, nargs='+', help='The telemetry key for KeyWrite operations')
parser.add_argument('--redundancy', type=int, nargs='+', help='The telemetry redundancy for KeyWrite operations')
parser.add_argument('--listID', type=int, nargs='+', help='The telemetry list ID for Append operations')
parser.add_argument('--loop', action='store_true', help='Indicates that the script should loop, generating traffic continuously')
parser.add_argument('--increment_data', action='store_true', help='Indicates that the data value should increment, if looping is enabled')
parser.add_argument('--increment_key', action='store_true', help='Indicates that the key-write key should increment, if looping is enabled')
parser.add_argument('--ipg', type=float, default=0.0, help='The IPG to replay traffic at, if emitting multiple packets simultaneously')
parser.add_argument('--batchsize', type=int, default=1, help='The batch size to use when --loop is enabled')

#args = vars(parser.parse_args())
args = parser.parse_args()
print(args)


class dta_base(Packet):
	name = "dtaBase"
	fields_desc = [ 
		XByteField("opcode",		0x01),
		XByteField("seqnum",		0), #DTA sequence number
		BitField("immediate",		0,		1),
		BitField("retransmitable",	0,		1),
		BitField("reserved", 		0,		6)
	]

class dta_keyWrite(Packet):
	name = "dtaKeyWrite"
	fields_desc = [ 
		ByteField("redundancy",	0x02),
		#IntField("key",		0),
		IntField("key",		0),
		IntField("data", 	0)
	]

class dta_append(Packet):
	name = "dtaAppend"
	fields_desc = [ 
		IntField("listID",		0),
		IntField("data", 	0)
	]

def craft_dta_keywrite(key, data, redundancy):
	print("Crafting a keywrite packet with key:%i data:%i, redundancy:%i" %(key,data,redundancy))
	
	key_bin = struct.pack(">I", key)
	
	pkt = Ether(dst="b8:ce:f6:d2:12:c7")\
	/IP(src="10.0.0.101",dst="10.0.0.51")\
	/UDP(sport=40041,dport=40040)\
	/dta_base(opcode=0x01)\
	/dta_keyWrite(redundancy=redundancy, key=RawVal(key_bin), data=data)
	#/dta_keyWrite(redundancy=redundancy, key=key, data=data)
	
	return pkt

def craft_dta_append(listID, data):
	print("Crafting an append packet with listID:%i data:%i" %(listID,data))
	
	pkt = Ether(dst="b8:ce:f6:d2:12:c7")\
	/IP(src="10.0.0.101",dst="10.0.0.51")\
	/UDP(sport=40041,dport=40040)\
	/dta_base(opcode=0x02)\
	/dta_append(listID=listID, data=data)
	
	return pkt

def emitPacket(pkts):
	ipg = args.ipg
	print("Sending %i DTA packet(s) at ipg:%.3f" %(len(pkts),ipg))
	sendp(pkts, inter=ipg, iface="enp4s0f0")

if args.operation[0] == "keywrite":
	print("Crafting a DTA KeyWrite packet...")
	
	assert args.key, "No telemetry key specified!"
	assert args.redundancy, "No telemetry redundancy specified!"
	assert args.data, "No telemetry data specified!"
	
	
	#Craft a KeyWrite packet
	key = args.key[0]
	data = args.data[0]
	redundancy = args.redundancy[0]
	doLoop = args.loop
	increment_data = args.increment_data
	increment_key = args.increment_key
	
	if doLoop: #Keep incrementing, used for one-off test of reliability
		batchSize = args.batchsize
		print("Looping enabled with batchsize %i" %batchSize)
		
		pkts = []
		while True: 
			pkt = craft_dta_keywrite(key=key, data=data, redundancy=redundancy)
			
			pkts.append(pkt)
			
			if len(pkts) >= batchSize:
				emitPacket(pkts)
				pkts = []
				print("sleeping 1 sec before next batch...")
				time.sleep(1)
			
			if increment_key:
				key = key + 1
			if increment_data:
				data = data + 1
			print("Incremented key:%i and data:%i" %(key,data))
	else: #This is default functionality. Craft and send a single packet
		print("Looping disabled, sending single packet")
		pkt = craft_dta_keywrite(key=key, data=data, redundancy=redundancy)
		emitPacket(pkt)

if args.operation[0] == "append":
	print("Crafting a DTA Append packet...")
	
	assert args.listID, "No telemetry list ID specified!"
	assert args.data, "No telemetry data specified!"
	doLoop = args.loop
	listID = args.listID[0]
	data = args.data[0]
	increment_data = args.increment_data
	
	if doLoop: #Keep incrementing, used for one-off test of reliability
		batchSize = args.batchsize
		print("Looping enabled with batchsize %i" %batchSize)
		
		pkts = []
		while True: 
			pkt = craft_dta_append(listID=listID, data=data)
			
			pkts.append(pkt)
			
			if len(pkts) >= batchSize:
				emitPacket(pkts)
				pkts = []
			
			if increment_data:
				data = data + 1
			print("Incremented data:%i" %(data))
	else:
		#Craft a single Append packet
		pkt = craft_dta_append(listID=listID, data=data)
		emitPacket(pkt)

