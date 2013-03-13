package Plugins::WebLogger::PlayerSettings;

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Web::Settings);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Web::HTTP::CSRF;

# XXX - Should switch to a better more-centralized module...but for now...
use Plugins::WebLogger::Plugin;

my $prefs = preferences('plugin.weblogger');
my $log   = logger('plugin.weblogger');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_WEBLOGGER_TITLE');
}

sub needsClient {
	return 1;
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/WebLogger/settings/player.html');
}

sub handler {
	my ($class, $client, $params) = @_;

	if ( $client ) {
		if ( $params->{saveSettings} ) {

			# Break down entered URL into it's bits for storage...but ONLY if it's changed?!
			if($params->{weblogger_storage_url} ne Plugins::WebLogger::Plugin::_getParam($client,'weblogger_storage_url')) {
				# It's changed...needs update...

				# When an FTP url is entered, we need to extract the username and password, and
				# store them (encrypted for a small bit of security)...parse it, and save the new
				# info...
				my($tempurl,$tempusername,$temppassword)=Plugins::WebLogger::Plugin::_ExtractURLInfo($params->{weblogger_storage_url});

				# Save the extracted username and password, and set our current value of the URL, as that will be written below...
				$params->{weblogger_storage_url}=$tempurl;
				$params->{weblogger_ftp_username}=$tempusername;
				$params->{weblogger_ftp_password}=Plugins::WebLogger::Plugin::passEncrypt($temppassword);

				# The info gets stored below...

			} else {
				# The storage URL hasn't changed, but we may have a username/password combo stored in the prefs that IS NOT being submitted with this params update, so make sure they stay intact...
				$params->{weblogger_ftp_username}=Plugins::WebLogger::Plugin::_getParam($client,'weblogger_ftp_username');
				$params->{weblogger_ftp_password}=Plugins::WebLogger::Plugin::passDecrypt(Plugins::WebLogger::Plugin::_getParam($client,'weblogger_ftp_password'));
			}

			Plugins::WebLogger::Plugin::_saveAllParams($client,$params);
			$params->{prefs}=Plugins::WebLogger::Plugin::_loadAllParams($client);

		} else {
			# Load all prefs into $params->{prefs}...
			$params->{prefs}=Plugins::WebLogger::Plugin::_loadAllParams($client);

		}

		# Load in our current custom templates for selection/display...
		my $temp_templates=Plugins::WebLogger::Plugin::_getCustomTemplateNames($client);
		$params->{prefs}{weblogger_output_playing_template_options}=$temp_templates->{weblogger_output_playing_template_options};
		$params->{prefs}{weblogger_output_stopped_template_options}=$temp_templates->{weblogger_output_stopped_template_options};

	}
	
	return $class->SUPER::handler( $client, $params );
}

1;

__END__
