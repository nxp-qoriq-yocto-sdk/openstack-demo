#!/bin/sh

usage_message() {
	echo "Usage: $0 [-C] [-c] [-n]
	-C: to install controller node services
	-c: to install compute node services
	-n: to install network node services
	"
}

if [ "$#" = "0" ]
then
	usage_message;
	exit 1;
fi

controller_flag=''
compute_flag=''
network_flag=''
block_storage_flag=''
object_storage_flag=''
while getopts Ccnboh opt_value
do
	case $opt_value in
		C) controller_flag='true';
			;;
		c) compute_flag='true';
			;;
		n) network_flag='true';
			;;
		b) block_storage_flag='true';
			;;
		o) object_storage_flag='true';
			;;
		?) usage_message;exit 1;
			;;
	esac
done

if [ -n "$controller_flag" ]
then
	read -p "Controller Node Management Interface IP: " controller_ip
	read -p "neutron_metadata_proxy_shared_secret: " metadata_secret
	if [ "$controller_ip" = "" ]; then
	echo "ERROR:No Ip Address for Management Interface" 
	exit
	fi

	cd Icehouse_conf/controller
	find . -type f | xargs perl -p -i -e "s|icehouse-controller|$controller_ip|g"
	find . -type f | xargs perl -p -i -e "s|METADATA_SECRET|$metadata_secret|g"

	path=`which ls`
	if echo `file $path.coreutils`|grep 64-bit > /dev/null 2>&1
	then
		cp mysql/mysql_64_bit/my.cnf /etc/my.cnf
	else
		cp mysql/myql_32_bit/my.cnf /etc/my.cnf
	fi

	/etc/init.d/mysqld restart
	sleep 10

	read -p "Mysql server User :" myuser
	read -p "Mysql server Password:" mypass

	mysql -u$myuser -p$mypass <<EOF
	drop database keystone;
	drop database glance;
	drop database nova;
	drop database neutron;
EOF

	#create database for keystone, glance, nova, neutron
	mysql -u$myuser -p$mypass <<EOF
	CREATE DATABASE keystone;
	GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY 'KEYSTONE_DBPASS';
	GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY 'KEYSTONE_DBPASS';
	GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'$controller_ip' IDENTIFIED BY 'KEYSTONE_DBPASS';
	CREATE DATABASE glance;
	GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY 'GLANCE_DBPASS';
	GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY 'GLANCE_DBPASS';
	GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'$controller_ip' IDENTIFIED BY 'GLANCE_DBPASS';
	CREATE DATABASE nova;
	GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY 'NOVA_DBPASS';
	GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY 'NOVA_DBPASS';
	GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'$controller_ip' IDENTIFIED BY 'NOVA_DBPASS';
	CREATE DATABASE neutron;
	GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY 'NEUTRON_DBPASS';
	GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY 'NEUTRON_DBPASS';
	GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'$controller_ip' IDENTIFIED BY 'NEUTRON_DBPASS';
	CREATE DATABASE cinder;
	GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY 'CINDER_DBPASS';
	GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY 'CINDER_DBPASS';
	GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'$controller_ip' IDENTIFIED BY 'CINDER_DBPASS';
	FLUSH PRIVILEGES;
EOF

	# Change Keystone configuration file
	cp -f keystone/keystone.conf /etc/keystone

	keystone-manage db_sync

	/etc/init.d/keystone restart
	unset OS_PASSWORD OS_AUTH_URL OS_USERNAME OS_TENANT_NAME SERVICE_ENDPOINT SERVICE_TOKEN
	export OS_USERNAME=admin
	export OS_PASSWORD=ADMIN_PASS
	export OS_TENANT_NAME=admin
	export OS_AUTH_URL=http://$controller_ip:35357/v2.0
	sleep 10

	#create an administrative user
	keystone user-create --name=admin --pass=ADMIN_PASS --email=ADMIN_EMAIL
	keystone role-create --name=admin
	keystone tenant-create --name=admin --description="Admin Tenant"
	keystone user-role-add --user=admin --tenant=admin --role=admin
	keystone user-role-add --user=admin --role=_member_ --tenant=admin

	#create a normal user
	keystone user-create --name=demo --pass=DEMO_PASS --email=DEMO_EMAIL
	keystone tenant-create --name=demo --description="Demo Tenant"
	keystone user-role-add --user=demo --role=_member_ --tenant=demo

	#create a service tenant
	keystone tenant-create --name=service --description="Service Tenant"

	#Define services and API endpoints
	keystone service-create --name=keystone --type=identity --description="OpenStack Identity"
	keystone endpoint-create --service-id=$(keystone service-list | awk '/ identity / {print $2}') \
	--publicurl=http://$controller_ip:5000/v2.0 --internalurl=http://$controller_ip:5000/v2.0 \
	--adminurl=http://$controller_ip:35357/v2.0

	cp -f glance/glance-api.conf /etc/glance/glance-api.conf
	cp -f glance/glance-registry.conf etc/glance/glance-registry.conf
	glance-manage db_sync
	sleep 10
	keystone user-create --name=glance --pass=GLANCE_PASS --email=glance@example.com
	keystone user-role-add --user=glance --tenant=service --role=admin
	keystone service-create --name=glance --type=image --description="OpenStack Image Service"
	keystone endpoint-create --service-id=$(keystone service-list | awk '/ image / {print $2}') \
	--publicurl=http://$controller_ip:9292 --internalurl=http://$controller_ip:9292 --adminurl=http://$controller_ip:9292

	/etc/init.d/glance-registry restart
	/etc/init.d/glance-api restart

	#Nova configuration
	cp -f nova/nova.conf /etc/nova/nova.conf
	nova-manage db sync
	sleep 10

	keystone user-create --name=nova --pass=NOVA_PASS --email=nova@example.com
	keystone user-role-add --user=nova --tenant=service --role=admin
	keystone service-create --name=nova --type=compute --description="OpenStack Comute"
	keystone endpoint-create --service-id=$(keystone service-list | awk '/ compute / {print $2}') \
	--publicurl=http://$controller_ip:8774/v2/%\(tenant_id\)s --internalurl=http://$controller_ip:8774/v2/%\(tenant_id\)s \
	--adminurl=http://$controller_ip:8774/v2/%\(tenant_id\)s
	/etc/init.d/nova-api restart
	/etc/init.d/nova-scheduler restart
	/etc/init.d/nova-conductor restart

	#Install network service
	keystone user-create --name=neutron --pass=NEUTRON_PASS --email=neutron@example.com
	keystone user-role-add --user=neutron --tenant=service --role=admin
	keystone service-create --name=neutron --type=network --description="OpenStack Networking"
	keystone endpoint-create --service-id=$(keystone service-list | awk '/ network / {print $2}') \
	--publicurl=http://$controller_ip:9696 --adminurl=http://$controller_ip:9696 --internalurl=http://$controller_ip:9696
	
	nova_admin_tenant_id=$(keystone tenant-get service | awk '/ id / {print $4}')
	find . type f | xargs perl -p -i -e "s||$nova_admin_tenant_id|g"
	
	cp -f neutron/neutron.conf /etc/neutron/neutron.conf
	cp -f neutron/plugins/openvswitch/ovs_neutron_plugin.ini /etc/neutron/plugins/openvswitch/ovs_neutron_plugin.ini

	/etc/init.d/nova-api restart
	/etc/init.d/nova-scheduler restart
	/etc/init.d/nova-conductor restart
	/etc/init.d/neutron-server restart
	
	#Install cinder storage service
	cp -f cinder/cinder.conf /etc/cinder/cinder.conf
	cinder-manage db sync
	keystone user-create --name=cinder --pass=CINDER_PASS --email=cinder@example.com
	keystone user-role-add --user=cinder --tenant=service --role=admin
	keystone service-create --name=cinder --type=volume --description="OpenStack Block Storage"
	keystone endpoint-create --service-id=$(keystone service-list | awk '/ volume / {print $2}') \
	--publicurl=http://$controller_ip:8776/v1/%\(tenant_id\)s \
	--internalurl=http://$controller_ip:8776/v1/%\(ternat_id\)s \
	--adminurl=http://$controller_ip:8776/v1/%\(ternat_id\)s
	
	keystone service-create --name=cinderv2 --type=volumerv2 --description="OpenStack Block Storage v2"
	keystone endpoint-create --service-id=$(keystone service-list | awk '/ volumev2 / {print $2}') \
	--publicurl=http://$controller_ip:8776/v2/%\(tenant_id\)s \
	--internalurl=http://$controller_ip:8776/v2/%\(tenant_id\)s \
	--adminurl=http://$controller_ip:8776/v2/%\(tenant_id\)s
	
	/etc/init.d/cinder-scheduler restart
	/etc/init.d/cinder-api restart
fi

if [ -n "$compute_flag" ]
then
	read -p "Controller Node Management Interface IP: " controller_ip
	read -p "Compute Node Data Interface IP: " data_ip

	unset OS_PASSWORD OS_AUTH_URL OS_USERNAME OS_TENANT_NAME SERVICE_ENDPOINT SERVICE_TOKEN
	export OS_USERNAME=admin
	export OS_PASSWORD=ADMIN_PASS
	export OS_TENANT_NAME=admin
	export OS_AUTH_URL=http://$controller_ip:35357/v2.0
	
	cd Icehouse_conf/compute
	find . -type f | xargs perl -p -i -e "s|icehouse-controller|$controller_ip|g"
	find . -type f | xargs perl -p -i -e "s|tunnel-ip|$data_ip|g"
	
	cp -f nova/nova.conf /etc/nova/nova.conf
	nova-manage db sync
	/etc/init.d/nova-compute restart
	
	cp -f neutron/neutron.conf /etc/neutron/neutron.conf
	cp -f neutron/plugins/openvswitch/ovs_neutron_plugin.ini /etc/neutron/plugins/openvswitch/ovs_neutron_plugin.ini
	/etc/init.d/openvswitch-switch restart
	/etc/init.d/nova-compute restart
	/etc/init.d/neutron-openvswitch-agent restart
	
fi

if [ -n "$network_flag" ]
then
	read -p "Controller Node Management Interface IP: " controller_ip
	read -p "Network Node Data Interface IP: " data_ip
	read -p "metadata_proxy_shared_secret, this secret must be the same with controller node neutron_metadata_proxy_shared_secret:" metadata_secret
	
	unset OS_PASSWORD OS_AUTH_URL OS_USERNAME OS_TENANT_NAME SERVICE_ENDPOINT SERVICE_TOKEN
	export OS_USERNAME=admin
	export OS_PASSWORD=ADMIN_PASS
	export OS_TENANT_NAME=admin
	export OS_AUTH_URL=http://$controller_ip:35357/v2.0
	
	cd Icehouse_conf/network
	find . -type f | xargs perl -p -i -e "s|icehouse-controller|$controller_ip|g"
	find . -type f | xargs perl -p -i -e "s|tunnel-ip|$data_ip|g"
	find . -type f | xargs perl -p -i -e "s|METADATA_SECRET|$metadata_secret|g"
	
	cp -f neutron/neutron.conf /etc/neutron/nertron.conf
	cp -f neutron/dhcp_agent.ini /etc/neutron/dhcp_agent.ini
	cp -f neutron/l3_agent.ini /etc/neutron/l3_agent.ini
	cp -f neutron/metadata_agent.ini /etc/neutron/metadata_agent.ini
	cp -f neutron/plugins/openvswitch/ovs_neutron_plugin.ini /etc/neutron/plugins/openvswitch/ovs_neutron_plugin.ini

	/etc/init.d/openvswitch-switch restart
	ovs-vsctl add-br br-ex
	read -p "Input your network node physical external network interface: " interface_name
	ovs-vsctl add-port br-ex $interface_name
	
	/etc/init.d/neutron-openvswitch-agent restart
	/etc/init.d/neutron-l3_agent restart
	/etc/init.d/neutron-dhcp_agent restart
	/etc/init.d/neutron-metadata_agent restart
fi

if [ -n "$block_storage_flag" ]
then

fi

if [ -n "$object_storage_flag" ]
then

fi
