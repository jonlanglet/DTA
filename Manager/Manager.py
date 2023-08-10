#!/usr/bin/env python3
#This script manages the entire DTA system. This is the script you want to run.

import time

#from common import log, debug, strToPktrate
from Tofino import Tofino
from Collector import Collector
from Generator import Generator

host_tofino = "jonatan@138.37.32.13" #Point to the Tofino
host_collector = "jlanglet@138.37.32.24" #Point to the collector
host_generator = "jlanglet@138.37.32.28" #Point to the traffic generator


def setup(do_reboot=False, manual_collector=True):
	#Reboot the machines and wait for them to come back online
	if do_reboot:
		systems = [tofino, collector, generator]
		
		#Reboot all
		for system in systems:
			system.reboot()
		
		#Wait for all to come online
		for system in systems:
			while not system.testConnection():
				print("%s is offline..." %system.name)
				time.sleep(20)


	tofino.flashPipeline()
	tofino.confPorts()

	tofino.configureNetworking()
	collector.setupCollector()

	if manual_collector:
		print("sudo /home/jlanglet/rdma/playground/collector_new")
		input("Start the DTA collector and press ENTER")
	else:
		collector.startCollector()


	tofino.startController()

	if not manual_collector:
		collector.verifyRDMAConnections() #Manually disabled

	generator.setup()

def Menu():
	print("1: \t(S)tart up DTA environment")
	print("2: \t(T)ofino menu")
	print("3: \t(C)ollector menu")
	print("4: \t(G)enerator menu")
	
	option = input("Selection: ").lower()
	
	if option in ["s","1"]: #Setup
		resp = input("Reboot machines? (y/N): ")
		do_reboot = resp == "y"
		resp = input("Start collector manually? (y/N): ")
		manual_collector = resp == "y"
		
		setup(do_reboot=do_reboot, manual_collector=manual_collector)
		
	if option in ["t","2"]: #Tofino
		tofino.ui_menu()
		
	if option in ["c","3"]: #Collector
		collector.ui_menu()
		
	if option in ["g","4"]: #Generator
		generator.ui_menu()


#Set up connection to machines
tofino = Tofino(host=host_tofino, pipeline="dta_translator")
collector = Collector(host=host_collector)
generator = Generator(host=host_generator)

#Loop the menu
while True:
	Menu()
