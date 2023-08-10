#!/usr/bin/env python

#from scapy.all import send, IP, ICMP
from scapy.all import *
import random
import sys

if len(sys.argv) == 1:
	pktID = random.randint(1,1000)
	print("Using random pktID=%i" %pktID)
else:
	pktID = int(sys.argv[1])
	print("Using pktID=%i" %pktID)

pkt = Ether()/IP(src="10.0.0.101",dst="10.0.0.102",id=pktID,ttl=255)

print("Sending packet", pkt)
sendp(pkt, iface="enp4s0f0")
