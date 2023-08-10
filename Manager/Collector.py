#!/usr/bin/env python3
#This script handled communication with the collector

import pexpect
import time
import datetime

from Machine import Machine

class Collector(Machine):
	ssh_collector = None
	interface = None
	ip = None
	
	def __init__(self, host, name="Collector"):
		self.host = host
		self.name = name
		self.log("Initiating %s at %s..." %(self.name, host))
	
		assert self.testConnection(), "Connection to the Collector does not work!"
	
	def configureNetworking(self):
		self.log("Configuring networking...")
		
		ssh = self.init_ssh()
		
		time.sleep(0.5)
		
		ssh.sendline("./network_setup.sh")
		i = ssh.expect(["$", pexpect.TIMEOUT], timeout=10)
		assert i == 0, "Timeout while running network setup script!"
		
		#Check IP assignment
		ssh.sendline("ifconfig ens1f1np1")
		i = ssh.expect(["10.0.0.51", pexpect.TIMEOUT], timeout=2)
		assert i == 0, "Network interface failed to configure!"
		
		#Check one of the ARP rules
		ssh.sendline("arp 10.0.0.101")
		i = ssh.expect(["84:c7:8f:00:6d:b3", pexpect.TIMEOUT], timeout=2)
		assert i == 0, "ARP rules failed to update!"
		
		time.sleep(2)
		
		self.debug("Networking is set up.")
	
	def disabelICRCVerification(self):
		self.log("Disabling iCRC verification on the NIC...")
		
		ssh = self.init_ssh()
		
		ssh.sendline("./disable-icrc.sh")
		i = ssh.expect(["WARNING: this script assumes", pexpect.TIMEOUT], timeout=2)
		assert i == 0, "Failed to start the disable-icrc.sh script!"
		
		i = ssh.expect(["$", pexpect.TIMEOUT], timeout=10)
		assert i == 0, "Timeout while running icrc disabling script!"
		
		time.sleep(5)
		
		self.debug("iCRC verification is now disabled")
	
	def setupRDMA(self):
		self.log("Setting up RDMA...")
		
		ssh = self.init_ssh()
		
		ssh.sendline("./rdma/setup_rdma.sh")
		i = ssh.expect(["Removing old modules", pexpect.TIMEOUT], timeout=2)
		assert i == 0, "Failed to start setup_rdma.sh!"
		
		i = ssh.expect(["INFO System info file", pexpect.TIMEOUT], timeout=20)
		assert i == 0, "Timeout while setting up RDMA!"
		
		time.sleep(2)
		
		self.debug("RDMA is now set up and configured!")
	
	def recompileRDMA(self):
		self.log("Recompiling RDMA...")
		
		ssh = self.init_ssh()
		
		ssh.sendline("cd rdma/rdma-core")
		ssh.expect("$", timeout=2)
		
		ssh.sendline("sudo ./build.sh")
		i = ssh.expect(["Build files have been written to", pexpect.TIMEOUT], timeout=30)
		assert i == 0, "Failed to build rdma-core!"
		
		self.debug("RDMA-core is now built")
		
		ssh.sendline("cd ~/rdma/mlnx_ofed/MLNX_OFED_SRC-5.5-1.0.3.2")
		ssh.expect("$", timeout=2)
		
		ssh.sendline("sudo ./install.pl")
		i = ssh.expect(["Checking SW Requirements", pexpect.TIMEOUT], timeout=30)
		assert i == 0, "Failed to start the mlnx_ofed installation!"
		self.debug("mlnx_ofed is now installing prerequisites...")
		
		i = ssh.expect(["This program will install the OFED package on your machine.", pexpect.TIMEOUT], timeout=180)
		assert i == 0, "Stuck at installing prerequisites!"
		
		i = ssh.expect(["Uninstalling the previous version of OFED", pexpect.TIMEOUT], timeout=180)
		assert i == 0, "Something went wrong!"
		self.debug("Uninstalling the previous version of OFED...")
		
		i = ssh.expect(["Building packages", pexpect.TIMEOUT], timeout=300)
		assert i == 0, "Stuck at uninstalling old OFED!"
		self.debug("Building new OFED (this will take a while)...")
		
		i = ssh.expect(["Installation passed successfully", pexpect.TIMEOUT], timeout=1800)
		assert i == 0, "Installation failed or timed out!"
		
		self.debug("OFED is now reinstalled!")
		
		
	
	def compileCollector(self):
		self.log("Compiling the collector service...")
		
		ssh = self.init_ssh()
		
		ssh.sendline("cd ./rdma/playground")
		ssh.expect("$", timeout=2)
		
		ssh.sendline("mv ./collector_new ./collector_backup_new")
		ssh.expect("$", timeout=2)
		
		ssh.sendline("./compile.sh")
		i = ssh.expect(["Compiling DTA Collector...", pexpect.TIMEOUT], timeout=10)
		assert i == 0, "Compilation did not start!"
		
		i = ssh.expect(["Compilation done", pexpect.TIMEOUT], timeout=20)
		assert i == 0, "Timeout while compiling collector service!"
		
		ssh.sendline("ls -l")
		i = ssh.expect(["collector_new", pexpect.TIMEOUT], timeout=5)
		assert i == 0, "Failed to compile collector service!"
		
		self.debug("Compilation finished")
	
	def killOldCollector(self):
		self.debug("Killing old collectors, if any are running")
		ssh = self.init_ssh()
		ssh.sendline("sudo killall collector_new")
		i = ssh.expect(["$", pexpect.TIMEOUT], timeout=10)
		assert i == 0, "Timeout while killing old collector service(s)!"
		
		time.sleep(2)
	
	def setupCollector(self):
		self.log("Setting up the collector...")
		
		self.killOldCollector()
		
		self.setupRDMA()
		#self.compileCollector()
		self.configureNetworking()
		self.disabelICRCVerification()
		self.setupRDMA()
		
	def startCollector(self):
		self.log("Starting the DTA collector service...")
		
		self.ssh_collector = self.init_ssh()
		
		self.debug("Starting the service...")
		self.ssh_collector.sendline("sudo ./rdma/playground/collector_new")
		i = self.ssh_collector.expect(["Press ENTER to analyze storage.", pexpect.TIMEOUT], timeout=10)
		assert i == 0, "Failed to start the DTA collector!"
		
		
		time.sleep(3) #Give time for various primitive threads to complete
		
		i = self.ssh_collector.expect(["Segmentation fault", pexpect.TIMEOUT], timeout=2)
		assert i == 1, "The collector returned a segfault during startup!"
		
		time.sleep(2)
		
		self.log("DTA collector service is now running")
		
	def verifyRDMAConnections(self):
		self.log("Verifying RDMA connections from the translator")
		
		
		self.ssh_collector.sendline("") #Send an enter to collector service
		numStructures = 0
		while True:
			i = self.ssh_collector.expect(["Printing RDMA info for ", pexpect.TIMEOUT], timeout=5)
			if i == 0:
				numStructures += 1
				self.debug("Found output for DTA structure. Total %i" %numStructures)
			else:
				break
		
		self.log("There seems to be %i active DTA structures" %numStructures)
		assert numStructures > 0, "No RDMA connections were detected at the collector!"
	
	def ui_menu(self):
		self.log("Entering menu")
		
		while True:
			print("1: \t(B)ack")
			print("2: \t(R)eboot")
			print("3: \tRe(c)ompile DTA collector")
			print("4: \t(S)tart collector service")
			print("5: \tS(e)tup RDMA")
			print("6: \tConfigure (n)etworking")
			print("7: \t(D)isable iCRC verification")
			
			option = input("Selection: ").lower()
			
			if option in ["b", "1"]:
				break
				
			if option in ["r","2"]:
				self.reboot()
				
			if option in ["c","3"]:
				self.compileCollector()
			
			if option in ["s","4"]:
				self.startCollector()
			
			if option in ["e","5"]:
				self.setupRDMA()
				
			if option in ["n","6"]:
				self.configureNetworking()
				
			if option in ["d","7"]:
				self.disabelICRCVerification()
			
			
			return
