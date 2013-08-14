require 'log4r'
require_relative '../../errors'

module VagrantWindows
  module Guest
    module Cap
      class ConfigureNetworks
        
        @@logger = Log4r::Logger.new("vagrant_windows::guest::cap::configure_networks")
        
        def self.configure_networks(machine, networks)
          @@logger.debug("networks: #{networks.inspect}")
          if (machine.provider_name != :vmware_fusion) && (machine.provider_name != :vmware_workstation)
            vm_interface_map = create_vm_interface_map(machine)
          end

          networks.each do |network|
            interface = vm_interface_map[network[:interface]+1]
            if interface.nil?
              @@logger.warn("Could not find interface for network #{network.inspect}")
            else
              configure_interface(machine, network, interface)
            end
          end
          set_networks_to_work(machine) if machine.config.windows.set_work_network
        end
        
        
        def self.is_dhcp_enabled(machine, interface_index)
          cmd = "Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter \"Index=#{interface_index} and DHCPEnabled=True\""
          # FIXME: this is moronic: if we find any output in the above command,
          # then we know DHCP is enabled for that interface. This is fragile,
          # but I have not found a better way of doing this than passing a proc
          # around
          has_dhcp_enabled = false
          block = Proc.new {|type, line| if line; has_dhcp_enabled=true; end}
          machine.communicate.execute(cmd, nil, &block)
          
          @@logger.debug("DHCP is enabled") if has_dhcp_enabled
          @@logger.debug("DHCP is disabled") unless has_dhcp_enabled
          
          has_dhcp_enabled
        end

        # Useful to allow guest access from the host via a private IP on Win7
        # https://github.com/WinRb/vagrant-windows/issues/63
        def self.set_networks_to_work(machine)
          @@logger.info("Setting networks to 'Work Network'")
          command = VagrantWindows.load_script("set_work_network.ps1")
          machine.communicate.execute(command)
        end
        
        #{1=>{:name=>"Local Area Connection", :mac_address=>"0800275FAC5B", :interface_index=>"11", :index=>"7"}}
        def self.create_vm_interface_map(machine)
          vm_interface_map = {}
          driver_mac_address = machine.provider.driver.read_mac_addresses.invert
          @@logger.debug("mac addresses: #{driver_mac_address.inspect}")
          get_network_adapter_array(machine).each do |nic|
            @@logger.debug("nic: #{nic.inspect}")
            naked_mac = nic[:mac_address].gsub(':','')
            if driver_mac_address[naked_mac]
              vm_interface_map[driver_mac_address[naked_mac]] = {
                :name => nic[:net_connection_id],
                :mac_address => naked_mac,
                :interface_index => nic[:interface_index],
                :index => nic[:index] }
            end
          end
          @@logger.debug("vm_interface_map: #{vm_interface_map.inspect}")
          vm_interface_map
        end
        
        #netsh interface ip set address "Local Area Connection 2"  static 192.168.33.10 255.255.255.0
        def self.configure_interface(machine, network, interface)
          @@logger.info("Configuring interface #{interface.inspect}")
          netsh = "netsh interface ip set address \"#{interface[:name]}\" "
          if network[:type].to_sym == :static
            netsh = "#{netsh} static #{network[:ip]} #{network[:netmask]}"
            machine.communicate.execute(netsh)
          elsif network[:type].to_sym == :dhcp
            # Setting an interface to dhcp if already enabled causes an error
            unless is_dhcp_enabled(machine, interface[:index])
              netsh = "#{netsh} dhcp"
              machine.communicate.execute(netsh)
            end
          else
            raise WindowsError, "#{network[:type]} network type is not supported, try static or dhcp"
          end
        end

        def self.get_network_adapter_array(machine)
          done = false
          result = []
          version = checkWSManVersion(machine)
          @@logger.debug("Version: #{version}")
          if Integer(version) == 2
            result = get_network_adapter_array_from_v2(machine)
          else
            result = get_network_adapter_array_from_v3(machine)                         
          end
          return result        
        end

        def self.checkWSManVersion(machine)
          @@logger.debug("Checking WSMan version.")
          script = '((test-wsman).productversion.split(" ") | select -last 1).split("\.")[0]'
          version = ''
          machine.communicate.execute(script) do |type, line|
            if type == :stdout
              if !line.nil?
                version = version + "#{line}"
              end
            end
          end
          @@logger.debug("Check WSMAN Version output #{version}")
          return version    
        end

        def self.get_network_adapter_array_from_v3(machine)
          @@logger.debug("Found WSMAN 3.  Trying workaround.")
          script = '$adapters = get-ciminstance win32_networkadapter -filter "macaddress is not null" 
$processed = @()
foreach ($adapter in $adapters)
{
    $Processed += new-object PSObject -Property @{
        mac_address = $adapter.macaddress
        net_connection_id = $adapter.netconnectionid
        interface_index = $adapter.interfaceindex
        index = $adapter.index
    }
 } 
 convertto-json -inputobject $processed
 '
          output = ''
          machine.communicate.execute(script) do |type, line|
            if type == :stdout
              if !line.nil?     
                @@logger.debug(line)           
                output = output + "#{line}"
              end
            end
          end
          @@logger.debug(output)
          adapterarray = JSON.parse(output)
          newadapterarray = []
          adapterarray.each do |nic|
            newadapterarray << nic.inject({}){|memo,(k,v)| memo[k.to_sym] = v; memo}
          end          
          @@logger.debug("Parsed output from PowerShell is #{newadapterarray.inspect}")
          newadapterarray.each do |nic|
            @@logger.warn("Checking parsed nic")
            @@logger.warn("    #{nic.inspect}")    
          end      
          return newadapterarray
        end

        def self.get_network_adapter_array_from_v2(machine)
          @@logger.debug("Using the tradditional method.")
          # Get all NICs that have a MAC address
          # http://msdn.microsoft.com/en-us/library/windows/desktop/aa394216(v=vs.85).aspx
          wql = 'SELECT * FROM Win32_NetworkAdapter WHERE MACAddress IS NOT NULL'
          result = machine.communicate.session.wql(wql)[:win32_network_adapter]
          return result
        end

      end
    end
  end
end
