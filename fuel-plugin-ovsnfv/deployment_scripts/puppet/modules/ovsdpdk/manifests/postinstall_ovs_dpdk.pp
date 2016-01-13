# == Class ovsdpdk::postinstall_ovs_dpdk
#
# Postinstall configuration of ovs-dpdk service
#
class ovsdpdk::postinstall_ovs_dpdk (
  $plugin_dir               = $::ovsdpdk::params::plugin_dir,
  $nova_conf                = $::ovsdpdk::params::nova_conf,
  $openvswitch_service_name = $::ovsdpdk::params::openvswitch_service_name,
  $ml2_conf                 = $::ovsdpdk::params::ml2_conf,
  $ml2_ovs_conf             = $::ovsdpdk::params::ml2_ovs_conf,
  $neutron_l3_conf          = $::ovsdpdk::params::neutron_l3_conf,
  $openvswitch_agent        = $::ovsdpdk::params::openvswitch_agent,
) inherits ovsdpdk {

  require ovsdpdk::install_ovs_dpdk

  package {'crudini': ensure => installed }

  if $compute == 'True' {
    # adapt configuration files
    exec {'adapt_nova_conf':
      command => "${plugin_dir}/files/set_vcpu_pin.sh ${nova_conf}",
      path    => ['/usr/bin','/bin'],
      user    => root,
      onlyif  => "test -f ${nova_conf}",
      require => Package['crudini'],
    }

    exec {'adapt_ml2_conf_datapath':
      command => "sudo crudini --set ${ml2_ovs_conf} ovs datapath_type ${ovs_datapath_type}",
      path    => ['/usr/bin','/bin'],
      user    => root,
      onlyif  => "test -f ${ml2_ovs_conf}",
      require => Package['crudini'],
    }

    exec {'adapt_neutron_l3':
      command => "sudo crudini --set ${neutron_l3_conf} DEFAULT external_network_bridge br-ex",
      path    => ['/usr/bin','/bin'],
      user    => root,
      onlyif  => "test -f ${neutron_l3_conf}",
      require => Package['crudini'],
    }


    service {"${openvswitch_service_name}": ensure => 'running' }

    # restart OVS to synchronize ovsdb-server with ovs-vswitchd needed
    # due to several new --no-wait entries
    exec {'restart_ovs':
      command => "/usr/sbin/service ${openvswitch_service_name} restart",
      user    => root,
      require => Service["${openvswitch_service_name}"],
    }

    exec { "${plugin_dir}/files/configure_bridges.sh ${ovs_datapath_type}":
      user    => root,
      require => Exec['restart_ovs'],
    }

    service { 'libvirtd': ensure => running }

    exec {'libvirtd_disable_tls':
      command => "sudo crudini --set /etc/libvirt/libvirtd.conf '' listen_tls 0",
      path    => ['/usr/bin','/bin'],
      user    => root,
      require => Package['crudini'],
      notify  => Service['libvirtd'],
    }

    exec {'restart_nova_compute':
      command => "/usr/sbin/service nova-compute restart",
      user    => root,
      require => [ Exec['libvirtd_disable_tls'], Service['libvirtd'] ],
    }
  }

  exec {'adapt_ml2_conf_mechanism_driver':
    command => "sudo crudini --set ${ml2_conf} ml2 mechanism_drivers ovsdpdk",
    path    => ['/usr/bin','/bin'],
    user    => root,
    onlyif  => "test -f ${ml2_conf}",
    require => Package['crudini'],
  }

  exec {'adapt_ml2_conf_security_group':
    command => "sudo crudini --set ${ml2_conf} securitygroup firewall_driver neutron.agent.firewall.NoopFirewallDriver",
    path    => ['/usr/bin','/bin'],
    user    => root,
    onlyif  => "test -f ${ml2_conf}",
    require => Package['crudini'],
  }

  if $controller == 'True' {
    service {'neutron-server':
      ensure => 'running',
    }

    exec {'append_NUMATopologyFilter':
      command => "sudo crudini --set ${nova_conf} DEFAULT scheduler_default_filters RetryFilter,AvailabilityZoneFilter,RamFilter,CoreFilter,DiskFilter,ComputeFilter,ComputeCapabilitiesFilter,ImagePropertiesFilter,ServerGroupAntiAffinityFilter,ServerGroupAffinityFilter,NUMATopologyFilter",
      path    => ['/usr/bin','/bin'],
      user    => root,
      onlyif  => "test -f ${nova_conf}",
      require => Package['crudini'],
    }

    exec { 'remove_old_agent':
      command => "${plugin_dir}/files/remove_agent.sh $adminrc_user $adminrc_password $adminrc_tenant $adminrc_hostname",
      user      => 'root',
      logoutput => 'true',
      timeout   => 0,
      require   => [ Service['neutron-server'], Exec['append_NUMATopologyFilter'] ],
    }

    exec {'restart_neutron_server':
      command => "/usr/sbin/service neutron-server restart",
      user    => root,
      require => Exec['remove_old_agent'],
    }

    exec {'restart_nova_scheduler':
      command => "/usr/sbin/service nova-scheduler restart",
      user    => root,
      require => Exec['remove_old_agent'],
    }

  }

  if $compute == 'True' {
    exec { 'patch_ovs_agent':
      command => "cp ${plugin_dir}/files/neutron-plugin-openvswitch-agent.conf /etc/init/neutron-plugin-openvswitch-agent.conf",
      path    => ['/usr/bin','/bin'],
      user    => root,
    }

    service {"${openvswitch_agent}":
      ensure  => 'running',
      require => [ Exec['restart_ovs'], Service["${openvswitch_service_name}"], Exec['patch_ovs_agent'] ],
    }

    exec { "ovs-vsctl --no-wait set Open_vSwitch . other_config:pmd-cpu-mask=${ovs_pmd_core_mask}":
      path    => ['/usr/bin','/bin'],
      user    => root,
      require => Service["${openvswitch_agent}"],
    }
  }

}