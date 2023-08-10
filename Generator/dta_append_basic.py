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

class dta_keyWrite(Packet):
	name = "dtaKeyWrite"
	fields_desc = [ 
		ByteField("redundancy",	0x02),
		IntField("key",		0),
		IntField("data", 	0)
	]

class dta_append(Packet):
	name = "dtaAppend"
	fields_desc = [ 
		IntField("listID",		0),
		IntField("data", 	0)
	]

class STLS1(object):
	
	def create_stream (self):
		base_pkt = Ether(dst="b8:ce:f6:d2:12:c7")\
			/IP(src="10.0.0.200",dst="10.0.0.51")\
			/UDP(sport=40041,dport=40040)\
			/dta_base(opcode=0x02)\
			/dta_append()
		
		vm = STLVM()
		
		num_lists = 4
		
	        #Increment srcIP for RSS
		vm.var(name='srcIP', size=4, op='random', step=1, min_value=0, max_value=2000000000)
		vm.write(fv_name='srcIP', pkt_offset='IP.src')


		#Increment sequence number
		vm.var(name='dta_seqnum', size=1, op='inc', step=1, min_value=0, max_value=255)
		vm.write(fv_name='dta_seqnum', pkt_offset='dta_base.seqnum')
		
		#Increment the data
		vm.var(name='dta_data', size=4, op='inc', step=1, min_value=1, max_value=1000000000) #Specify the data to append
		vm.write(fv_name='dta_data', pkt_offset='dta_append.data')
		
		#Round-robin on list IDs
		vm.var(name='dta_listID', size=4, op='inc', step=1, min_value=0, max_value=num_lists) #Specify which lists to append into
		vm.write(fv_name='dta_listID', pkt_offset='dta_append.listID')
		
		return STLStream(packet = STLPktBuilder(pkt = base_pkt, vm = vm), mode = STLTXCont())

	def get_streams (self, tunables, **kwargs):
		parser = argparse.ArgumentParser(description='Argparser for {}'.format(os.path.basename(__file__)), formatter_class=argparse.ArgumentDefaultsHelpFormatter)
		args = parser.parse_args(tunables)
		# create 1 stream 
		return [ self.create_stream() ]


# dynamic load - used for trex console or simulator
def register():
	return STLS1()



