from trex_stl_lib.api import *
import argparse


class teledata(Packet):
	name = "teledata"
	fields_desc = [ 
		IntField("key",0),
		IntField("data",0)
	]

class STLS1(object):
	
	def create_stream (self):
		base_pkt = Ether(dst="b8:ce:f6:d2:12:c7")\
			/IP(src="10.0.0.200",dst="10.0.0.51")\
			/UDP(sport=40041,dport=1337)\
			/teledata(key=123,data=666)\
		
		vm = STLVM()
		
	        #Increment srcIP for RSS
		vm.var(name='srcIP', size=4, op='random', step=1, min_value=0, max_value=2000000000)
		vm.write(fv_name='srcIP', pkt_offset='IP.src')


		#random key
		vm.var(name='telekey', size=4, op='inc', min_value=0, max_value=1000000000)
		vm.write(fv_name='telekey', pkt_offset='teledata.key')
		
		#Increment the data
		vm.var(name='teledat', size=4, op='inc', step=1, min_value=1, max_value=1000000000) #Specify the data to append
		vm.write(fv_name='teledat', pkt_offset='teledata.data')
	
		return STLStream(packet = STLPktBuilder(pkt = base_pkt, vm = vm), mode = STLTXCont())

	def get_streams (self, tunables, **kwargs):
		parser = argparse.ArgumentParser(description='Argparser for {}'.format(os.path.basename(__file__)), formatter_class=argparse.ArgumentDefaultsHelpFormatter)
		args = parser.parse_args(tunables)
		# create 1 stream 
		return [ self.create_stream() ]


# dynamic load - used for trex console or simulator
def register():
	return STLS1()



