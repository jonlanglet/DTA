from trex_stl_lib.api import *
import argparse


class dta_base(Packet):
	name = "dtaBase"
	fields_desc = [ 
		XByteField("opcode",		0x01),
		XByteField("seqnum",		0), #DTA sequence number
		BitField("immediate",		0,		1),
		BitField("retransmitable",	0,		1),
		BitField("reserved", 		0,		6)
	]

class dta_keyIncrement(Packet):
	name = "dtaKeyIncrement"
	fields_desc = [ 
		ByteField("redundancy",	0),
		IntField("key",		0),
		LongField("counter", 	0)
	]

class STLS1(object):
	
	def create_stream (self, redundancy=4, key=1, counter=1, seqnum=0):
		#redundancy = 4 #modify this for different redundancy tests
		#key = 1
		#data = 1
		#seqnum = 0
		
		base_pkt = Ether(dst="b8:ce:f6:d2:12:c7")\
			/IP(src="10.0.0.200",dst="10.0.0.51")\
			/UDP(sport=40041,dport=40040)\
			/dta_base(opcode=0x03,seqnum=seqnum)\
			/dta_keyIncrement(redundancy=redundancy, key=key, counter=counter)#, data2=2, data3=3)
		
		vm = STLVM()
		
		#Increment sequence number
		vm.var(name='dta_seqnum', size=1, op='inc', step=1, min_value=0, max_value=255)
		vm.write(fv_name='dta_seqnum', pkt_offset='dta_base.seqnum')
		
		#Increment key
		vm.var(name='dta_key', size=4, op='inc', step=1, min_value=0, max_value=1000000000)
		vm.write(fv_name='dta_key', pkt_offset='dta_keyIncrement.key')
		
		#Increment data
		vm.var(name='dta_counter', size=8, op='inc', step=1, min_value=0, max_value=1000000000)
		vm.write(fv_name='dta_counter', pkt_offset='dta_keyIncrement.counter')
		
		return STLStream(packet = STLPktBuilder(pkt = base_pkt, vm = vm), mode = STLTXCont())

	def get_streams (self, tunables, **kwargs):
		parser = argparse.ArgumentParser(description='Argparser for {}'.format(os.path.basename(__file__)), formatter_class=argparse.ArgumentDefaultsHelpFormatter)
		parser.add_argument('--redundancy', type=int, default=4, help='The KeyWrite redundancy')
		args = parser.parse_args(tunables)
		print(args)
		# create 1 stream 
		return [ self.create_stream(redundancy=int(args.redundancy)) ]


# dynamic load - used for trex console or simulator
def register():
	return STLS1()



