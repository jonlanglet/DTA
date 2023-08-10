#!/usr/bin/env python3
#This script prepares and launches a DTA pipeline on the Tofino switch, and prepares RDMA states
#Assuming our setup, and SDE 9.7.0



import pexpect
import time
import datetime

from Machine import Machine

#This is currently forced to only be the Translator Tofino
class Tofino(Machine):
	pipeline = None
	port_config = None
	essential_ports = None
	
	ssh_switchd = None
	ssh_controller = None
	
	def __init__(self, host, pipeline, name="Tofino"):
		self.host = host
		self.name = name
		self.pipeline = pipeline
		
		self.log("Initiating %s at %s..." %(self.name, host))
		
		#TODO: Move these centralized into some config file
		self.port_config = [
			"pm port-del -/-",
			"pm port-add 49/0 100G rs",
			"pm port-add 55/0 100G rs",
			"pm port-add 57/0 10G none",
			"pm port-add 57/1 10G none",
			"pm an-set 49/0 1",
			"pm an-set 55/0 1",
			"pm an-set 57/0 1",
			"pm an-set 57/1 1",
			"pm port-enb -/-",
			"bf_pltfm led",
			"led-task-cfg -r 1",
			"..",
			".."
		]
		self.essential_ports = [
			"49/0",
			"55/0",
			"57/0",
			"57/1",
		]
		
		assert self.testConnection(), "Connection to the Tofino does not work!"
	
	#This is currently forced to just compile the Translator pipeline
	def compilePipeline(self, enable_nack_tracking=True, num_tracked_nacks=65536, append_batch_size=4, resync_grace_period=100000, max_supported_qps=256):
		
		project = "dta_translator"
		p4_file = "~/projects/dta/translator/p4src/dta_translator.p4"
		
		self.log("Compiling project %s from source %s..." %(project, p4_file))
		
		assert append_batch_size in [1,2,4,8,16], "Unsupported Append batch size"
		
		
		ssh = self.init_ssh()
		
		#
		# Generate compilation command
		#
		preprocessor_directives = ""
		#Nack tracking/retransmission
		if enable_nack_tracking:
			preprocessor_directives += " -DDO_NACK_TRACKING"
			preprocessor_directives += " -DNUM_TRACKED_NACKS=%i" %num_tracked_nacks
		
		#Append batch size (num batched entries)
		preprocessor_directives += " -DAPPEND_BATCH_SIZE=%i" %append_batch_size
		preprocessor_directives += " -DNUM_APPEND_ENTRIES_IN_REGISTERS=%i" %(append_batch_size-1)
		preprocessor_directives += " -DAPPEND_RDMA_PAYLOAD_SIZE=%i" %(append_batch_size*4)
		
		#Grace period
		preprocessor_directives += " -DQP_RESYNC_PACKET_DROP_NUM=%i" %(resync_grace_period)
		
		#Max supported queue pairs
		preprocessor_directives += " -DMAX_SUPPORTED_QPS=%i" %(max_supported_qps)
		
		#Build actual compilation command out of components
		command = "bf-p4c --target tofino --arch tna --std p4-16 -g -o $P4_BUILD_DIR/%s/ %s %s && echo Compilation\ finished" %(project, preprocessor_directives, p4_file)
		
		self.debug("Executing '%s'..." %command)
		
		ssh.sendline(command)
		i = ssh.expect(["Compilation finished", "error:", pexpect.TIMEOUT], timeout=180)
		
		if i == 1:
			self.error("Compilation error!")
		elif i == 2:
			self.error("Compilation timeout!")
		
		assert i == 0, "Pipeline compilation failed!"
		
		self.debug("Compilation done!")
		
	
	def flashPipeline(self):
		self.ssh_switchd = self.init_ssh()
		
		#Killing old process (if one is running)
		self.ssh_switchd.sendline("sudo killall bf_switchd")
		self.ssh_switchd.expect("$", timeout=4)
		
		
		#Flash the pipeline
		self.log("Flashing pipeline %s at %s" %(self.pipeline, self.host))
		self.ssh_switchd.sendline("./start_p4.sh %s" %self.pipeline)
		
		i = self.ssh_switchd.expect(["Using SDE_INSTALL", pexpect.TIMEOUT], timeout=5)
		assert i == 0, "Failing to initiate pipeline statup!"
		
		self.debug("Pipeline is flashing...")
		
		i = self.ssh_switchd.expect(["WARNING: Authorised Access Only", pexpect.TIMEOUT], timeout=10)
		assert i == 0, "Failed to flash the pipeline!"
		self.debug("Pipeline '%s' is now running on host %s!" %(self.pipeline, self.host))
	
	def initBFshell(self):
		ssh = self.init_ssh()
		
		self.debug("Entering bfshell...")
		ssh.sendline("bfshell")
		i = ssh.expect(["WARNING: Authorised Access Only", pexpect.TIMEOUT], timeout=10)
		assert i == 0, "Failed to enter bfshell!"
		self.debug("bfshell established!")
		
		return ssh
	
	def initUCLI(self):
		ssh = self.initBFshell()
		
		self.debug("Entering ucli...")
		ssh.sendline("ucli")
		i = ssh.expect(["bf-sde", pexpect.TIMEOUT], timeout=5)
		assert i == 0, "Failed to enter ucli!"
		
		return ssh
	
	#This assumes that ports are already configured
	def verifyPorts(self):
		self.log("Verifying that ports are online...")
		
		ssh_ucli = self.initUCLI()
		
		ssh_ucli.sendline("pm")
		ssh_ucli.expect("bf-sde.pm>", timeout=2)
		
		for port in self.essential_ports:
			self.debug("Checking port %s..." %port)
			
			portUp = False
			for i in range(10):
				ssh_ucli.sendline("show %s" %port)
				i = ssh_ucli.expect([port, pexpect.TIMEOUT], timeout=10)
				assert i == 0, "Port %s was not configured!" %port
				
				i = ssh_ucli.expect(["UP", "DWN", pexpect.TIMEOUT], timeout=10)
				
				assert i != 2, "Timeout when checking port status!"
				if i == 1:
					self.debug("Port %s is down..." %port)
					time.sleep(5)
					continue
				elif i == 0:
					self.debug("Port %s is up!" %port)
					portUp = True
					break
			assert portUp, "Port %s did not come alive! Is the host connected and online?" %port
				
		
		self.debug("Ports are configured and ready for action!")
	
	#This assumes that a pipeline is already flashed, and a switchd session is running
	def confPorts(self):
		self.log("Configuring Tofino ports on %s..." %self.host)
		
		ssh_ucli = self.initUCLI()
		
		for cmd in self.port_config:
			self.debug(" > %s" %cmd)
			ssh_ucli.sendline(cmd)
			time.sleep(0.1)
		
		i = ssh_ucli.expect(["bf-sde.bf_pltfm.led", pexpect.TIMEOUT], timeout=5)
		assert i == 0, "Failed to enter port config commands!"
		
		time.sleep(1) #Give configuration time to trigger
		self.debug("Ports are now configured.")
		
		self.verifyPorts()
	
	def configureNetworking(self):
		self.log("Configuring networking...")
		
		ssh = self.init_ssh()
		
		ssh.sendline("./network_setup.sh")
		i = ssh.expect(["$", pexpect.TIMEOUT], timeout=10)
		assert i == 0, "Timeout while running network setup script!"
		
		#Check an IP assignment
		ssh.sendline("ifconfig enp4s0f0")
		i = ssh.expect(["10.0.0.101", pexpect.TIMEOUT], timeout=2)
		assert i == 0, "Network interface failed to configure!"
		
		#Check one of the ARP rules
		ssh.sendline("arp 10.0.0.51")
		i = ssh.expect(["b8:ce:f6:d2:12:c7", pexpect.TIMEOUT], timeout=2)
		assert i == 0, "ARP rules failed to update!"
		
		self.debug("Networking is set up.")
	
	def startController(self):
		self.log("Starting the controller...")
		
		#TODO: Make this into a parameter or dynamic depending on pipeline
		#file_script = "/home/jonatan/projects/dta/translator/switch_cpu.py"
		
		self.ssh_controller = self.init_ssh()
		
		self.ssh_controller.sendline("$SDE/run_bfshell.sh -b /home/jonatan/projects/dta/translator/switch_cpu.py -i")
		
		i = self.ssh_controller.expect(["Using SDE_INSTALL", pexpect.TIMEOUT], timeout=5)
		assert i == 0, "bfshell failed to start!"
		
		i = self.ssh_controller.expect(["DigProc: Starting", pexpect.TIMEOUT], timeout=5)
		assert i == 0, "Controller script failed to start!"
		self.debug("Controller script is starting...")
		
		#TODO: add checks that we hear back from the collector RDMA NIC here!
		
		i = self.ssh_controller.expect(["Inserting KeyWrite rules...", pexpect.TIMEOUT], timeout=5)
		assert i == 0, "Timeout waiting for keywrite preparation!"
		self.debug("Controller is configuring KeyWrite...")
		
		
		numConnections = 0
		while True:
			i = self.ssh_controller.expect(["DigProc: Setting up a new RDMA connection from virtual client...", pexpect.TIMEOUT], timeout=10)
			if i == 0:
				numConnections += 1
				self.debug("An RDMA connection is establishing at translator. Total %i" %numConnections)
			else:
				break
		
		self.log("There seems to be %i RDMA connections established at the translator" %numConnections)
		assert numConnections > 0, "No RDMA connections were detected at the translator!"
		
		i = self.ssh_controller.expect(["DigProc: Bootstrap complete", pexpect.TIMEOUT], timeout=60)
		assert i == 0, "Timeout waiting for controller to finish!"
		self.log("Controller bootstrap finished!")
	
	def ui_compilePipeline(self):
		self.log("Menu for compiling Translator pipeline.")
		
		#enable_nack_tracking
		resp = input("Enable NACK tracking? (Y/n): ")
		enable_nack_tracking = resp != "n"
		
		#num_tracked_nacks
		num_tracked_nacks = 0
		if enable_nack_tracking:
			resp = input("Num tracked NACKs? (Def:65536): ")
			if resp == "":
				num_tracked_nacks = 65536
			else:
				num_tracked_nacks = int(resp)
		
		#append_batch_size
		resp = input("Size of Append batches? (Def:4): ")
		if resp == "":
			append_batch_size = 4
		else:
			append_batch_size = int(resp)
		
		#resync_grace_period
		resp = input("Resync grace period? (Def:100000): ")
		if resp == "":
			resync_grace_period = 100000
		else:
			resync_grace_period = int(resp)
		
		#max_supported_qps
		resp = input("Number of supported QPs? (Def:256): ")
		if resp == "":
			max_supported_qps = 256
		else:
			max_supported_qps = int(resp)
		
		self.compilePipeline(enable_nack_tracking=enable_nack_tracking, num_tracked_nacks=num_tracked_nacks, append_batch_size=append_batch_size, resync_grace_period=resync_grace_period, max_supported_qps=max_supported_qps)
		
	def ui_menu(self):
		self.log("Entering menu")
		
		while True:
			print("1: \t(B)ack")
			print("2: \t(C)ompile pipeline")
			print("3: \t(F)lash pipeline")
			print("4: \tConfigure (p)orts")
			print("5: \tConfigure (n)etworking")
			print("6: \t(S)tart controller")
			print("7: \t(R)eboot")
			
			option = input("Selection: ").lower()
			
			if option in ["b", "1"]:
				break
					
			if option in ["c","2"]:
				self.ui_compilePipeline()
			
			if option in ["f","3"]:
				self.flashPipeline()
			
			if option in ["p","4"]:
				self.confPorts()
			
			if option in ["n","5"]:
				self.configureNetworking()
			
			if option in ["s","6"]:
				self.startController()
				
			if option in ["r","7"]:
				self.reboot()
		
