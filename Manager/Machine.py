#!/usr/bin/env python3
import time
import pexpect

from common import log

class Machine:
	host = None
	name = None
	
	def log(self, text):
		log("%s: \t%s" %(self.name, text))
	
	#High verbosity output
	def debug(self, text):
		self.log("  Debug: %s" %(text))
	
	def error(self, text):
		self.log("ERROR: %s" %(text))
	
	def reboot(self):
		self.log("Rebooting %s at %s" %(self.name, self.host))
		ssh = self.init_ssh()
		ssh.sendline("sudo reboot")
		i = ssh.expect([pexpect.EOF, pexpect.TIMEOUT], timeout=10)
		assert i == 0, "Failed to detect reboot!"
		
		time.sleep(1)
	
	def testConnection(self):
		self.debug("Testing connection to %s at %s..." %(self.name, self.host))
		
		p = pexpect.spawn("ssh %s" %self.host)
		i = p.expect(["Welcome to Ubuntu", "Connection refused", pexpect.TIMEOUT, pexpect.EOF], timeout=5)
		if i == 0:
			self.debug("Logged into %s" %self.host)
		elif i == 1:
			self.debug("Connection refused!")
			return False
		elif i == 2:
			self.debug("Connection timeout!")
			return False
		elif i == 3:
			self.debug("SSH terminates!")
			return False
		
		self.debug("Verifying command capability...")
		content = "Testing"
		p.sendline("echo \"%s\" > ssh_works" %content)
		p.expect("$")
		p.sendline("cat ssh_works")
		i = p.expect([content, pexpect.TIMEOUT], timeout=2)
		if i != 0:
			self.error("Did not find expected output!")
			return False
		
		self.debug("Commands work! Resetting and logging out...")
		
		p.sendline("rm ssh_works")
		p.expect("$")
		p.sendline("exit")
		time.sleep(1)
		
		p.close()
		
		return True
		
	def init_ssh(self):
		self.debug("Logging into %s at %s..." %(self.name, self.host))
		p = pexpect.spawn("ssh %s" %self.host)
		i = p.expect(["$", pexpect.TIMEOUT], timeout=5)
		
		if i != 0:
			self.error("Timeout!")
			return None
		
		self.debug("SSH to %s is initiated" %self.host)
		
		return p
