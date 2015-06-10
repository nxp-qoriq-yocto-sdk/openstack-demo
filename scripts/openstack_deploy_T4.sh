#!/bin/sh



controller_ip=localhost
data_ip=192.168.2.75

if [ "$controller_ip" = "" ]; then
echo "ERROR :No Ip Address for Management Interface"
exit
fi
if [ "$data_ip" = "" ]; then
echo "ERROR : No Ip Address for Data Interface"
exit
fi



#tar -zxvf Havana_conf.tgz
cd Havana_conf
find . -type f | xargs perl -p -i -e "s/havana-controller/$controller_ip/g"
find . -type f | xargs perl -p -i -e "s/havana-data/$data_ip/g"
find . -type f | xargs perl -p -i -e "s/havana-NN-data/$data_ip/g"
find . -type f | xargs perl -p -i -e "s/havana-NN-host/$controller_ip/g"
find . -type f | xargs perl -p -i -e "s/mng_interface/$mng_interface/g"
find . -type f | xargs perl -p -i -e "s/data_interface/$data_interface/g"

path=`which ls`
if echo `file $path.coreutils`|grep 64-bit > /dev/null 2>&1
then
    cp mysql/mysql_64_bit/my.cnf /etc/my.cnf
else
    cp mysql/mysql_32_bit/my.cnf /etc/my.cnf
fi

/etc/init.d/mysqld restart
sleep 10 

read -p  "Mysql server User :" myuser
read -p  "Mysql server password :" mypass

mysql -u$myuser -p$mypass <<EOF
drop database keystone;
drop database glance;
drop database nova;
drop database neutron;
EOF

#create databases for keystone, glance, nova, neutron
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
FLUSH PRIVILEGES;
EOF


### Change Keystone configuration file

cp -f keystone/keystone.conf /etc/keystone/
cp -f keystone/keystone-paste.ini /etc/keystone/
cp -f keystone/keystone-manage /usr/bin/
mkdir /var/log/keystone

keystone-manage db_sync

/etc/init.d/keystone restart

export OS_SERVICE_TOKEN=ADMIN_TOKEN
export OS_SERVICE_ENDPOINT=http://$controller_ip:35357/v2.0
sleep 10
keystone tenant-create --name=admin --description="Admin Tenant"
keystone tenant-create --name=service --description="Service Tenant"
keystone user-create --name=admin --pass=ADMIN_PASS --email=admin@example.com
keystone role-create --name=admin
keystone user-role-add --user=admin --tenant=admin --role=admin
keystone service-create --name=keystone --type=identity --description="Keystone Identity Service"
service_id=`mysql -h "$controller_ip" -ukeystone -pKEYSTONE_DBPASS keystone -ss -e "SELECT id FROM service WHERE type='identity';"`
keystone endpoint-create --service-id=$service_id --publicurl=http://$controller_ip:5000/v2.0 --internalurl=http://$controller_ip:5000/v2.0 --adminurl=http://$controller_ip:35357/v2.0
unset OS_SERVICE_TOKEN OS_SERVICE_ENDPOINT
export OS_USERNAME=admin
export OS_PASSWORD=ADMIN_PASS
export OS_TENANT_NAME=admin
export OS_AUTH_URL=http://$controller_ip:35357/v2.0
keystone user-list

###Glance configuration
cp -f glance/glance-api.conf /etc/glance/glance-api.conf
cp -f glance/glance-registry.conf /etc/glance/glance-registry.conf
cp -f glance/glance-api-paste.ini /etc/glance/glance-api-paste.ini
cp -f glance/glance-registry-paste.ini /etc/glance/glance-registry-paste.ini
glance-manage db_sync
sleep 10
keystone user-create --name=glance --pass=GLANCE_PASS --email=glance@example.com
keystone user-role-add --user=glance --tenant=service --role=admin
keystone service-create --name=glance --type=image --description="Glance Image Service"
service_id=`mysql -h "$controller_ip" -ukeystone -pKEYSTONE_DBPASS keystone -ss -e "SELECT id FROM service WHERE type='image';"`
keystone endpoint-create --service-id=$service_id --publicurl=http://$controller_ip:9292 --internalurl=http://$controller_ip:9292 --adminurl=http://$controller_ip:9292
/etc/init.d/glance-registry restart
/etc/init.d/glance-api restart

###Nova configuration
cp -f nova/nova.conf /etc/nova/nova.conf
cp -f nova/api-paste.ini /etc/nova/api-paste.ini
cp -f nova/nova-all /etc/init.d/nova-all
cp -f nova/nova-cert /etc/init.d/nova-cert
cp -f nova/nova-manage /etc/init.d/nova-manage
cp -f nova/nova-novncproxy /etc/init.d/nova-novncproxy
cp -f nova/nova-api /etc/init.d/nova-api
cp -f nova/nova-conductor /etc/init.d/nova-conductor
cp -f nova/nova-consoleauth /etc/init.d/nova-consoleauth
cp -f nova/nova-scheduler /etc/init.d/nova-scheduler
cp -f nova/nova-network /etc/init.d/nova-network
mkdir /var/log/nova
nova-manage db sync
sleep 10
keystone user-create --name=nova --pass=NOVA_PASS --email=nova@example.com
keystone user-role-add --user=nova --tenant=service --role=admin
keystone service-create --name=nova --type=compute --description="Nova Compute service"
service_id=`mysql -h "$controller_ip" -ukeystone -pKEYSTONE_DBPASS keystone -ss -e "SELECT id FROM service WHERE type='compute';"`
keystone endpoint-create --service-id=$service_id --publicurl=http://$controller_ip:8774/v2/%\(tenant_id\)s --internalurl=http://$controller_ip:8774/v2/%\(tenant_id\)s --adminurl=http://$controller_ip:8774/v2/%\(tenant_id\)s

`mysql -h "$controller_ip" -unova -pNOVA_DBPASS nova -ss -e "alter table compute_nodes add column data_ip varchar(15);;"`

/etc/init.d/nova-api restart

/etc/init.d/nova-cert restart

/etc/init.d/nova-consoleauth restart

/etc/init.d/nova-scheduler restart

/etc/init.d/nova-conductor restart

/etc/init.d/nova-novncproxy restart

#Install network service
cp -f neutron/neutron.conf /etc/neutron/neutron.conf
cp -f neutron/l3_agent.ini /etc/neutron/
cp -f neutron/api-paste.ini /etc/neutron/api-paste.ini
cp -f neutron/dhcp_agent.ini /etc/neutron/dhcp_agent.ini
cp -f neutron/metadata_agent.ini /etc/neutron/metadata_agent.ini
cp -f neutron/plugins/openvswitch/ovs_neutron_plugin.ini /etc/neutron/plugins/openvswitch/ovs_neutron_plugin.ini

cp -f neutron/neutron-server /etc/init.d/neutron-server
cp -f neutron/neutron-dhcp-agent /etc/init.d/neutron-dhcp-agent
cp -f neutron/neutron-l3-agent /etc/init.d/neutron-l3-agent
cp -f neutron/neutron-metadata-agent /etc/init.d/neutron-metadata-agent

#cp -fr neutron/plugins/ml2/drivers/freescale /usr/lib/python2.7/site-packages/neutron/plugins/ml2/drivers/
#cp -fr neutron/services/firewall/fsl_fwaas_plugin.py /usr/lib/python2.7/site-packages/neutron/services/firewall/
#cp -f neutron/entry_points.txt /usr/lib/python2.7/site-packages/neutron-2013.2.2.dev2.ge79771e-py2.7.egg-info/entry_points.txt

keystone user-create --name=neutron --pass=NEUTRON_PASS --email=neutron@example.com
keystone user-role-add --user=neutron --tenant=service --role=admin
keystone service-create --name=neutron --type=network --description="OpenStack Networking Service"
service_id=`mysql -h "$controller_ip" -ukeystone -pKEYSTONE_DBPASS keystone -ss -e "SELECT id FROM service WHERE type='network';"`
keystone endpoint-create --service-id $service_id --publicurl http://$controller_ip:9696 --adminurl http://$controller_ip:9696 --internalurl http://$controller_ip:9696

/etc/init.d/neutron-server restart
/etc/init.d/neutron-dhcp-agent restart
/etc/init.d/neutron-l3-agent restart
/etc/init.d/neutron-metadata-agent restart
/etc/init.d/neutron-openvswitch-agent restart
ovs-vsctl add-br br-int
/etc/init.d/neutron-openvswitch-agent restart 
