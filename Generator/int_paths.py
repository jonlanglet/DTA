from trex_stl_lib.api import *
import argparse


class int_flow(Packet):
	name = "intFlow"
	fields_desc = [ 
		IntField("srcIP", 1),
		IntField("dstIP", 1),
		XByteField("proto",	0x06),
		ShortField("srcPort", 1),
		ShortField("dstPort", 1)
	]
class int_path(Packet):
	name = "intPath"
	fields_desc = [ 
		IntField("s1", 1),
		IntField("s2", 1),
		IntField("s3", 1),
		IntField("s4", 1),
		IntField("s5", 1)
	]



class STLS1(object):
	
	def create_stream (self):
		
		base_pkt = Ether(dst="b4:96:91:b3:ac:e8")\
			/IP(src="10.0.0.51",dst="10.0.0.200")\
			/UDP(sport=5000,dport=5002)\
			/int_flow()\
			/int_path()
		
		vm = STLVM()
		
		#Generate random flow tuples
		vm.var(name='srcIP', min_value=1, max_value=10000000, size=4, op='random')
		vm.var(name='dstIP', min_value=1, max_value=10000000, size=4, op='random')
		vm.var(name='srcPort', min_value=1, max_value=65535, size=2, op='random')
		vm.var(name='dstPort', min_value=1, max_value=65535, size=2, op='random')
		vm.var(name='proto', min_value=1, max_value=2, size=1, op='random')
		vm.write(fv_name='srcIP', pkt_offset='int_flow.srcIP')
		vm.write(fv_name='dstIP', pkt_offset='int_flow.dstIP')
		vm.write(fv_name='proto', pkt_offset='int_flow.proto')
		vm.write(fv_name='srcPort', pkt_offset='int_flow.srcPort')
		vm.write(fv_name='dstPort', pkt_offset='int_flow.dstPort')
		
		#Set some random hops
		vm.var(name='s1', min_value=1, max_value=10000, size=4, op='random')
		vm.var(name='s2', min_value=1, max_value=10000, size=4, op='random')
		vm.var(name='s3', min_value=1, max_value=10000, size=4, op='random')
		vm.var(name='s4', min_value=1, max_value=10000, size=4, op='random')
		vm.var(name='s5', min_value=1, max_value=10000, size=4, op='random')
		vm.write(fv_name='s1', pkt_offset='int_path.s1')
		vm.write(fv_name='s2', pkt_offset='int_path.s2')
		vm.write(fv_name='s3', pkt_offset='int_path.s3')
		vm.write(fv_name='s4', pkt_offset='int_path.s4')
		vm.write(fv_name='s5', pkt_offset='int_path.s5')
		
		return STLStream(packet = STLPktBuilder(pkt = base_pkt, vm = vm), mode = STLTXCont())

	def get_streams (self, tunables, **kwargs):
		parser = argparse.ArgumentParser(description='Argparser for {}'.format(os.path.basename(__file__)), formatter_class=argparse.ArgumentDefaultsHelpFormatter)
		args = parser.parse_args(tunables)
		# create 1 stream 
		return [ self.create_stream() ]


# dynamic load - used for trex console or simulator
def register():
	return STLS1()



 
