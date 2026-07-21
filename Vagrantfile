Vagrant.configure("2") do |config|
  config.vm.box = "debian/bookworm64"
  config.vm.box_check_update = true

  bridge_adapter = ENV.fetch("WAZUH_BRIDGE_ADAPTER", "eno1")

  # Bridge the VMs onto the same LAN as the host. The default values match the
  # host's current 192.168.0.0/24 network, and can be overridden per run with
  # WAZUH_INDEXER_IP, WAZUH_MANAGER_IP, WAZUH_DASHBOARD_IP, or
  # WAZUH_BRIDGE_ADAPTER.
  nodes = {
    "indexer" => { ip: ENV.fetch("WAZUH_INDEXER_IP", "192.168.0.110"), memory: 4096, cpus: 2, disk_size: 102400, mount: "/var/lib/wazuh-indexer" },
    "manager" => { ip: ENV.fetch("WAZUH_MANAGER_IP", "192.168.0.111"), memory: 4096, cpus: 2, disk_size: 102400, mount: "/var/lib/wazuh-manager" },
    "dashboard" => { ip: ENV.fetch("WAZUH_DASHBOARD_IP", "192.168.0.112"), memory: 4096, cpus: 2, disk_size: 30720, mount: "/var/lib/wazuh-dashboard" }
  }

  disks_dir = File.expand_path("disks", __dir__)
  require "fileutils"
  FileUtils.mkdir_p(disks_dir)

  nodes.each do |role, settings|
    config.vm.define role do |node|
      node.vm.hostname = "wazuh-#{role}"
      node.vm.network "public_network", bridge: bridge_adapter, auto_config: false

      case role
      when "indexer"
        node.vm.network "forwarded_port", guest: 9200, host: 19_200, host_ip: "127.0.0.1"
      when "manager"
        node.vm.network "forwarded_port", guest: 1514, host: 1514, host_ip: "127.0.0.1"
        node.vm.network "forwarded_port", guest: 1515, host: 1515, host_ip: "127.0.0.1"
        node.vm.network "forwarded_port", guest: 55000, host: 55_000, host_ip: "127.0.0.1"
      when "dashboard"
        node.vm.network "forwarded_port", guest: 443, host: 8443, host_ip: "127.0.0.1"
      end

      node.vm.provider "virtualbox" do |vb|
        vb.name = "wazuh-local-#{role}"
        vb.memory = settings[:memory]
        vb.cpus = settings[:cpus]
        vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]

        # Vagrant does not manage this disk, so `vagrant destroy` keeps Wazuh
        # data intact. Delete only disks/<role>.vdi when a clean data reset is
        # explicitly wanted.
        disk = File.join(disks_dir, "#{role}.vdi")
        unless File.exist?(disk)
          vb.customize ["createmedium", "disk", "--filename", disk, "--format", "VDI", "--size", settings[:disk_size].to_s]
        end
        vb.customize ["storageattach", :id, "--storagectl", "SATA Controller", "--port", "1", "--device", "0", "--type", "hdd", "--medium", disk]
      end

      node.vm.provision "shell", path: "provision/bootstrap.sh", privileged: true, run: "always", env: {
        "WAZUH_ROLE" => role,
        "WAZUH_DATA_MOUNT" => settings[:mount],
        "WAZUH_NODE_IP" => settings[:ip],
        "WAZUH_BRIDGE_INTERFACE" => "eth1",
        "WAZUH_INDEXER_IP" => nodes["indexer"][:ip],
        "WAZUH_MANAGER_IP" => nodes["manager"][:ip],
        "WAZUH_DASHBOARD_IP" => nodes["dashboard"][:ip]
      }
    end
  end
end
