#!/usr/bin/env python3
#This script handled communication with the generator

import pexpect
import time
import datetime

from common import strToPktrate
from Machine import Machine

class Generator(Machine):
	interface = None
	ip = None
	
	ssh_trex = None
	ssh_trexConsole = None
	
	def __init__(self, host, name="Generator"):
		self.host = host
		self.name = name
		self.log("Initiating %s at %s..." %(self.name, host))
	
		assert self.testConnection(), "Connection to the Generator does not work!"
	
	def configureNetworking(self):
		self.log("Configuring networking...")
		
		ssh = self.init_ssh()
		
		ssh.sendline("./network_setup.sh")
		i = ssh.expect(["$", pexpect.TIMEOUT], timeout=10)
		assert i == 0, "Timeout while running network setup script!"
		
		#Check IP assignment (disabled, dpdk will remove this interface)
		#ssh.sendline("ifconfig ens2f0")
		#i = ssh.expect(["10.0.0.200", pexpect.TIMEOUT], timeout=2)
		#assert i == 0, "Network interface failed to configure!"
		
		#Check one of the ARP rules
		#ssh.sendline("arp 10.0.0.51")
		#i = ssh.expect(["b8:ce:f6:d2:12:c7", pexpect.TIMEOUT], timeout=2)
		#assert i == 0, "ARP rules failed to update!"
		
		self.log("Networking is set up.")
	
	def startTrex(self):
		self.log("Starting TReX...")
		
		self.ssh_trex = self.init_ssh()
		self.ssh_trex.sendline("cd ./generator/trex")
		i = self.ssh_trex.expect("$", timeout=5)
		
		self.log("Launching trex service")
		self.ssh_trex.sendline("sudo ./t-rex-64 -i -c 16")
		i = self.ssh_trex.expect(["Starting Scapy server", pexpect.TIMEOUT], timeout=10)
		assert i == 0, "Trex does not respond!"
		
		i = self.ssh_trex.expect(["Global stats enabled", pexpect.TIMEOUT], timeout=30)
		assert i == 0, "Trex start timed out!"
		
		
		
		
	def startTrexConsole(self):
		self.log("Starting TReX Console...")
		self.ssh_trexConsole = self.init_ssh()
		
		self.ssh_trexConsole.sendline("cd ./generator/trex")
		i = self.ssh_trexConsole.expect("$", timeout=2)
		
		self.ssh_trexConsole.sendline("./trex-console")
		i = self.ssh_trexConsole.expect(["Server Info", pexpect.TIMEOUT], timeout=5)
		assert i == 0, "Console does not launch!"
		
		self.ssh_trexConsole.sendline("./trex-console")
		i = self.ssh_trexConsole.expect(["trex>", pexpect.TIMEOUT], timeout=10)
		assert i == 0, "Console timed out!"
		
		self.log("TReX Console is running!")
		
		time.sleep(2)
		
	def setup(self):
		self.log("Setting up the generator")
		
		self.configureNetworking()
		self.startTrex()
		self.startTrexConsole()
	
	#TODO: make this check Tofino rate-show!
	def findCurrentRate(self):
		trafficFlowing = False
		for i in range(10):
			
			time.sleep(2)
			
			#Clear the output buffer
			self.ssh_trex.read_nonblocking(1000000000, timeout = 1)
			i = self.ssh_trex.expect(["Total-PPS       :       0.00  pps", pexpect.TIMEOUT], timeout=1)
			
			if i == 1:
				trafficFlowing = True
				break
			else:
				self.log("No traffic yet...")
		
		if not trafficFlowing:
			return 0
		
		#assert trafficFlowing, "TReX does not actually generate traffic!"
		
		#Retrieve reported packet rate
		self.ssh_trex.expect("Total-PPS", timeout=3)
		rate_str = self.ssh_trex.readline()
		rate_str = rate_str.decode('ascii').replace(" ", "").replace(":", "").replace("\r\n", "")
		self.debug("The reported rate is: %s" %rate_str)
		
		return strToPktrate(rate_str)
	
	def waitForSpeed(self, speed_target, error_target=0.1):
		#Check in trex daemon that traffic is actually generating
		self.log("Checking in TReX daemon that traffic is flowing...")
		
		#Wait for the traffic to be in the correct range
		rate_target = strToPktrate(speed_target)
		for i in range(10):
			time.sleep(2)
			rate = self.findCurrentRate()
			
			error = 1 - rate/rate_target
			
			self.debug("We generate %s pps, the target is %s pps" %(str(rate), str(rate_target)))
			
			if error < error_target:
				self.debug("The speed error is acceptable: %s" %str(error))
				break
			
			self.debug("The speed error is too large: %s" %str(error))
			
		assert error < error_target, "The traffic rate error is too large!"
		
		self.log("Traffic is flowing correctly!")
	
	#Start STL-based replays
	def startTraffic_script(self, script="stl/dta_keywrite_basic.py", speed="1kpps", tuneables=""):
		self.log("Starting traffic generation script %s at speed %s" %(script, speed))
		
		cmd = "start -f %s -m %s -t %s" %(script, speed, tuneables)
		print(cmd)
		self.ssh_trexConsole.sendline(cmd)
		i = self.ssh_trexConsole.expect(["Starting traffic on port", "are active - please stop them or specify", pexpect.TIMEOUT], timeout=10)
		
		if i == 1:
			self.error("Can't start traffic, already running!")
		
		assert i != 2, "Traffic generation start timed out!"
		
		self.waitForSpeed(speed) #Wait until the target rate is achieved
	
	#Push Marple PCAP
	def startTraffic_pcap(self, pcap, speed="1kpps"):
		self.log("Replaying pcap %s at speed %s" %(pcap, speed))
		
		rate = strToPktrate(speed)
		print("rate", rate)
		
		ipg = 1000000/rate
		print("ipg", ipg)
		
		cmd = "push --force -f %s -p 0 -i %f -c 0 --dst-mac-pcap" %(pcap, ipg)
		
		print(cmd)
		self.ssh_trexConsole.sendline(cmd)
		i = self.ssh_trexConsole.expect(["Starting traffic on port", "are active - please stop them or specify", pexpect.TIMEOUT], timeout=10)
		
		if i == 1:
			self.error("Can't start traffic, already running!")
		
		assert i != 2, "Traffic generation start timed out!"
		
		self.waitForSpeed(speed) #Wait until the target rate is achieved
	
	def startTraffic_keywrite(self, speed="1kpps", redundancy=4):
		self.log("Replaying KeyWrite traffic at redundancy %i and speed %s" %(redundancy, speed))
		
		tuneables = "--redundancy %i" %(redundancy)
		self.startTraffic_script(script="stl/dta_keywrite_basic.py", speed=speed, tuneables=tuneables)
	
	def startTraffic_keyincrement(self, speed="1kpps", redundancy=4):
		self.log("Replaying KeyIncrement traffic at redundancy %i and speed %s" %(redundancy, speed))
		
		tuneables = "--redundancy %i" %(redundancy)
		self.startTraffic_script(script="stl/dta_keyincrement_basic.py", speed=speed, tuneables=tuneables)
	
	def startTraffic_append(self, speed="1kpps"):
		self.log("Replaying Append traffic at speed %s" %(speed))
		
		tuneables = ""
		self.startTraffic_script(script="stl/dta_append_basic.py", speed=speed, tuneables=tuneables)
	
	def startTraffic_marple(self):
		speed = input("Speed (e.g., 1mpps): ")
		pcap = "/home/jlanglet/generator/marple_dta.pcap"
		
		self.startTraffic_pcap(pcap, speed)
	
	def stopTraffic(self):
		self.log("Stopping traffic generation")
		
		self.ssh_trexConsole.sendline("stop")
		i = self.ssh_trexConsole.expect(["Stopping traffic on port", "no active ports", pexpect.TIMEOUT], timeout=5)
		if i == 1:
			self.error("No traffic is playing! Nothing to stop")
			
		assert i != 2, "Traffic stop timed out!"
	
	def ui_startTraffic(self):
		speed = input("Speed (e.g., 1mpps): ")
			
		#Configure and run primitive
		while True:
			
			primitive = input("Primitive (keywrite, append, keyincrement): ")
			
			if primitive == "keywrite":
				redundancy = int(input("Redundancy: "))
				self.startTraffic_keywrite(speed=speed, redundancy=redundancy)
			
			elif primitive == "append":
				self.startTraffic_append(speed=speed)
			
			elif primitive == "keyincrement":
				redundancy = int(input("Redundancy: "))
				self.startTraffic_keyincrement(speed=speed, redundancy=redundancy)
				
				
			else:
				print("Invalid choice")
				continue
			
			print("Started")
			
			break
	
	def ui_menu(self):
		self.log("Entering menu")
		
		while True:
			print("1: \t(B)ack")
			print("2: \t(S)tart traffic (script)")
			print("3: \tStart (M)arple traffic")
			print("4: \tS(t)op traffic")
			print("5: \t(K)ill console")
			print("6: \t(R)eboot")
			
			option = input("Selection: ").lower()
			
			if option in ["b", "1"]:
				break
				
			if option in ["s","2"]:
				self.ui_startTraffic()
			
			if option in ["m","3"]:
				self.startTraffic_marple()
			
			if option in ["t","4"]:
				self.stopTraffic()
			
			if option in ["k","5"]:
				self.log("Removing reference of TReX console!")
				self.ssh_trexConsole = None
			
			if option in ["r","5"]:
				self.reboot()
			
