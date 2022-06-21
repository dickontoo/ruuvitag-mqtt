#!/usr/bin/perl
#
# ruuvitag-mqtt.pl
#
# Listen for BT events, and submit anything that looks taglike to mqtt.

use strict;
use Net::DBus;
use Net::DBus::Dumper;
use Net::DBus::Reactor;
use Net::MQTT::Simple '172.29.23.1';
use JSON::MaybeXS;
use Data::Dumper;

my %pretty = (
	'e2:a0:a3:f2:6b:b3' => 'office',
	'dc:58:98:8f:ba:b5' => 'kitchen',
	'e2:e0:97:93:75:d0' => 'tellyroom',
	'f3:c1:e4:c5:01:17' => 'outside',
);

use vars qw/$bluez %known/;


sub ub16
{
	my ($t, $b) = @_;
	return ($t << 8) | $b;
}



sub sb16
{
	my $u16 = ub16(@_);
	$u16 = $u16-65536 if ($u16 > 32768);
	return $u16;
}



sub parse
{
	my %o;
	my $p;

	$o{'version'} = shift;
	$o{'temperature'} = sb16(shift, shift) * 0.005;
	$o{'humidity'} = ub16(shift, shift) * 0.0025;
	$o{'pressure'} = (ub16(shift, shift)+50000) / 100;
	$o{'x-accel'} = sb16(shift, shift);
	$o{'y-accel'} = sb16(shift, shift);
	$o{'z-accel'} = sb16(shift, shift);
	$p = ub16(shift, shift);
	$o{'movement'} = shift;
	$o{'sequence'} = ub16(shift, shift);
	$o{'mac'} = sprintf("%02x:%02x:%02x:%02x:%02x:%02x", @_);

	$o{'battery'} = (($p & 0xffe0) >> 5)/1000 + 1.6;
	$o{'txpower'} = (($p & 0x1f) * 2) + -40;
	$o{'name'} = $pretty{$o{'mac'}} or $o{'mac'};

	return \%o;
}


sub changed
{
	my ($path, $scrap, $dset) = @_;
	if (not exists $$dset{'ManufacturerData'}{'1177'}) {
		return;
	}
	my $data = parse(@{$$dset{'ManufacturerData'}{'1177'}});
	my $json = encode_json($data)."\n";
	retain "ruuvi/$$data{'name'}" => $json;
}

sub newint
{
	my ($path, $dev) = @_;

	return if $known{$path};
	$known{$path} = 1;
	if ($$dev{'org.bluez.Device1'}{'Name'} =~ /^Ruuvi\ /) {
		print "It's tag\n";
		my $obj = $bluez->get_object($path, 'org.freedesktop.DBus.Properties');
		my $sigid = $obj->connect_to_signal('PropertiesChanged', sub { &changed($path, @_) });
	} else {
		print "It isn't a tag\n";
	}

}

my $bus = Net::DBus->system;

$bluez = $bus->get_service('org.bluez');
my $hci = $bluez->get_object('/org/bluez/hci0', 'org.bluez.Adapter1');
$hci->StartDiscovery();
my $bobj = $bluez->get_object('/',  'org.freedesktop.DBus.ObjectManager');
my $sigif = $bobj->connect_to_signal('InterfacesAdded', \&newint);
my $mobjs = $bobj->GetManagedObjects();
for (keys %$mobjs) {
	my $k = $_;
	if ($$mobjs{$k}{'org.bluez.Device1'}{'Name'} =~ /^Ruuvi\ /) {
		my $obj = $bluez->get_object($k, 'org.freedesktop.DBus.Properties');
		my $sigid = $obj->connect_to_signal('PropertiesChanged', sub { &changed($k, @_) });
	}
	$known{$k} = 1;
}

my $reactor = Net::DBus::Reactor->main();
$reactor->run();

sleep(10) while(1);

