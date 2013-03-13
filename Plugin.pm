package Plugins::WebLogger::Plugin;

# This code is derived from code with the following copyright message:
#
# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Plugin::Base);
use Plugins::WebLogger::PlayerSettings;
use Scalar::Util qw(blessed);
use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Utils::DateTime;
use Slim::Utils::Timers;
use Slim::Web::HTTP;
use Slim::Player::Source;
use Slim::Web::Pages;
use Slim::Web::Graphics;

use URI::Escape;
use Net::FTP;
use File::Temp;
use HTTP::Request::Common qw(POST GET);
use LWP::UserAgent;

use vars qw($VERSION);
$VERSION = '1.11';

# Our preferences object for get/set of prefs...
my $prefs = preferences('plugin.weblogger');

# Vars to keep track of menu, current selection, last updated song, etc...
my %active_client_list;
my @browseMenuChoices;

my %defaultConfigs=(
	weblogger_status			=> 0,
	weblogger_status_display		=> 'ALL',
	weblogger_status_display_time		=> 2,
	weblogger_log_tracknum			=> 0,
	weblogger_log_title			=> 1,
	weblogger_log_duration			=> 0,
	weblogger_log_composer			=> 0,
	weblogger_log_album			=> 1,
	weblogger_log_genre			=> 0,
	weblogger_log_year			=> 0,
	weblogger_log_artist			=> 1,
	weblogger_log_conductor			=> 0,
	weblogger_log_bitrate			=> 0,
	weblogger_log_comment			=> 0,
	weblogger_log_tagversion		=> 0,
	weblogger_log_timestamp			=> 1,
	weblogger_log_albumart			=> 1,
	weblogger_log_playername		=> 0,
	weblogger_log_webloggerversion		=> 0,
	weblogger_storage_url			=> 'file://c:\\',
	weblogger_update_timeout		=> 5,
	weblogger_http_method			=> 'POST',
	weblogger_http_checkforok		=> 1,
	weblogger_output_playing_template	=> 'Text.template.txt',
	weblogger_output_filename		=> 'songinfo.txt',
	weblogger_output_stopped_file_enabled	=> 1,
	weblogger_output_stopped_template	=> 'Text.template.txt',
	weblogger_albumart_type			=> 'THUMB',
	weblogger_albumart_filename		=> 'albumart.jpg',
	weblogger_albumart_filename_prefix	=> '',
	weblogger_albumart_always		=> 1,
	weblogger_ftp_username			=> '',
	weblogger_ftp_password			=> '',
	weblogger_ftp_keepalive			=> 'JUSTOPEN',
	weblogger_ftp_dummyfile			=> '000DUMMY.DAT',
	weblogger_ftp_passive			=> 0,
	weblogger_last_update			=> 'n/a'
);

# Locations of our templates within our plugin's HTML directory...
my $_WEBLOGGER_PLAYING_TEMPLATE_DIR='plugins/WebLogger/templates/playing';
my $_WEBLOGGER_STOPPED_TEMPLATE_DIR='plugins/WebLogger/templates/stopped';

# Turns on debugging text output...
my $_DEBUG=1;

# Logging object...
my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.weblogger',
	'defaultLevel' => 'INFO',
	'description'  => getDisplayName(),
});

# This is an old friend from pre-SC7 days
# It returns the name to display on the squeezebox
sub getDisplayName {
	return 'PLUGIN_WEBLOGGER_TITLE';
}

# Another old friend from pre-SC7 days.
# This is called when SC loads the plugin.
# So use it to initialize variables and the like.
sub initPlugin {
	my $class = shift;

	$log->debug("Initializing");
		
	# These next two appear to be things that have to be done when initializing the plugin in SC7.
	# Not sure what they do.
	$class->SUPER::initPlugin();
	# Note the plugin-specific field here. This may instantiate the web interface for the plugin.
	Plugins::WebLogger::PlayerSettings->new;

	# Register a callback function so that the server knows we want to hook in...
	Slim::Control::Request::subscribe(\&songChangeCallback,[['playlist'],['open']]);
	Slim::Control::Request::subscribe(\&playbackStoppedCallback,[['power','stop']]);

}

sub shutdownPlugin
{
	# XXX - Kill the executecallback...
}

sub playbackStoppedCallback
{
	my($request)=@_;
	my $client=$request->client();
	my $command=$request->getRequest(0);

	# Stop button pressed, or squeezebox client powered down...in either case
	# we should display a "STOPPED" page...

	# ...but ONLY if we've got a previously stored song...just incase this is
	# a quick power-up power-down combo...no sense wasting time with an
	# update in that case...

	# ...also...if this is a power-down during song playback, Slim::Player::Source::playmode($client)
	# is "pause" which makes doUpdate() not do it's job properly...so that's
	# why we have the "ispowerdown" flag to pass in as 1 in this case...

	if((_getParam($client,'weblogger_status'))&&(_getParam($client,'weblogger_output_stopped_file_enabled'))&&($active_client_list{$client->macaddress()}{lastsonginfo})&&(!doUpdate($client,undef,1,1))) {
		# There was an error, so display it...we can't use showBriefly() in the
		# normal way because we are stopped, or shutting down, and the display will be
		# over-written as soon as this is done, so we have to sleep to make sure
		# the message is displayed.
		my $errorstring=$@;
		$log->error($client->string('PLUGIN_WEBLOGGER_UI_TITLE_ERROR').": $errorstring");
		showFailure($client,$errorstring,1);
	}

	# Only on powerdown...kill our FTP object and keep-alive timer...
	if (($command eq 'power')&&($client->can('power'))) {
		if(!$client->power()) {
			_killFTP($client);
		}
	}

}

sub songChangeCallback
{
	my($request)=@_;
	my $client=$request->client();
	my $fileurl=$request->getRequest(2);

	# Hook for when a new song is opened for playing/buffering...

	# $fileurl will contain the file URL...
	# Example : file:///M:/Aerosmith/Greatest%20Hits/09%20Come%20Together.mp3

	# A new song is about to be played...
	# Get the currently playing song, and it's tag information, and write it where specified...
	# (but only if this plugin is ENABLED)

	if((_getParam($client,'weblogger_status'))&&(!doUpdate($client,$fileurl,1,0))) {
		# There was an error, so display it...we can't use showBriefly() in the
		# normal way because we are between songs, and the display will be
		# over-written as soon as this is done, so we have to sleep to make sure
		# the message is displayed.
		my $errorstring=$@;
		$log->error($client->string('PLUGIN_WEBLOGGER_UI_TITLE_ERROR').": $errorstring");
		showFailure($client,$errorstring,1);
	}

}

sub _ExtractURLInfo
{
	my($url)=@_;

	# This function breaks down a URL to username, password and URL for storage...
	# (we do this so we can hide the password from being seen in the web interface mainly)

	# Rips the specified URL apart into the bits we need...
	my ($username,$password,$newurl)=();
	if($url=~/^ftp:\/\/(.*):(.*)@(.*)$/i) {
		$username=uri_unescape($1 || '');
		$password=uri_unescape($2 || '');
		$newurl='ftp://'.uri_unescape($3 || '');
		return($newurl,$username,$password);
	}

	# URL wasn't parsed as FTP, or it was invalid...in any case...just store it as-is...
	return($url,'','');
}

sub setMode
{
	my($class,$client,$method)=@_;

	# This is called whenever this plugin's config menu is entered from the main plugins menu...

	# Create a list of our main menu items...
	@browseMenuChoices = (
		$client->string('SETUP_UI_WEBLOGGER_STATUS'),
		$client->string('SETUP_UI_WEBLOGGER_MANUAL_UPDATE'),
		$client->string('SETUP_UI_WEBLOGGER_LAST_UPDATE'),
		$client->string('SETUP_UI_WEBLOGGER_ABOUT'),
	);

	# Initialize our client's position in that menu if needed...
	unless (defined($active_client_list{$client->macaddress()}{activemenu})) {
		$active_client_list{$client->macaddress()}{activemenu} = 0;
	}

	$client->lines(\&lines);
}

sub lines
{
	my($client)=@_;

	# Take care of displaying the main menu...no matter what item we're currently nav'd to...

	return({
		'line'   => [
			$client->string('PLUGIN_WEBLOGGER_UI_TITLE'),
			$browseMenuChoices[$active_client_list{$client->macaddress()}{activemenu}] || '',
		],
		'overlay' => [
			undef,
			$client->symbols('rightarrow'),
		],
	});
}
	
sub showSuccess
{
	my($client,$message,$withsleep)=@_;
	my $displaySetting=_getParam($client,'weblogger_status_display');
	my $displayTime=_getParam($client,'weblogger_status_display_time');
	if(($displaySetting eq 'ALL')||($displaySetting eq 'SUCCESS')) {
		# Show the message...
		$log->info('SUCCESS: '.$message);
		$client->showBriefly(
			{ line => [ $client->string('PLUGIN_WEBLOGGER_UI_TITLE')." v$VERSION",$message ] },
			{ duration => $displayTime }
		);

		# Sometimes we need to SLEEP, otherwise, another showBriefly could clobber
		# this one before we get a chance to see it...
		sleep($displayTime) if($withsleep);
	}
}

sub showFailure
{
	my($client,$message,$withsleep)=@_;
	my $displaySetting=_getParam($client,'weblogger_status_display');
	my $displayTime=_getParam($client,'weblogger_status_display_time');
	if(($displaySetting eq 'ALL')||($displaySetting eq 'FAILURE')) {
		# Show the message...
		$log->error('ERROR: '.$message);
		$client->showBriefly(
			{ line => [ $client->string('PLUGIN_WEBLOGGER_UI_TITLE_ERROR')." v$VERSION",$message ] },
			{ duration => $displayTime }
		);

		# Sometimes we need to SLEEP, otherwise, another showBriefly could clobber
		# this one before we get a chance to see it...
		sleep($displayTime) if($withsleep);
	}
}

sub isValidClient
{
	my($client)=@_;
	
	# Just tests to see if the object is in fact a valid client object...
	
	if((defined($client))&&(ref($client)=~/^Slim::Player::/)) {
		# We have a valid client/player object...it's safe to do what we will...
		return(1);
	}
	return(0);
}

###############################################################################

sub _getParamRef
{
	my($client,$prefName)=@_;
	my $val=_getParam($client,$prefName);
	return(\$val);
}

sub _getParam
{
	my($client,$prefName)=@_;
	my $returnValue;

	# Reads a preference for this plugin from the main pref file, and if it's not set yet, returns the specified default...

	# If we're not using a real client...just return the defaults...
	# (although they have no use at this point?!)

	if(!isValidClient($client)) {
		$log->error("_getParam($prefName) : No valid client object provided.");
		return($defaultConfigs{$prefName});
	}

	# Get the value of the preference...it's stored as part of the plugin's prefs...
	$returnValue=$prefs->client($client)->get($prefName);

	# If no setting was retrieved, use the specified default...
	if(!defined($returnValue)) {
		$returnValue=$defaultConfigs{$prefName};
	}

	$log->debug("Param \"$prefName\" retrieved.  ($returnValue)");
	return($returnValue);
}

sub _setParam
{
	my($client,$prefName,$value)=@_;

	# Writes a preference for this plugin to the main preference file...

	# If we're not using a real client...we can't go and save it can we???

	if(!isValidClient($client)) {
		$log->error("_setParam($prefName,$value) : No valid client object provided.");
		return(0);
	}

	# Set the pref...
	$prefs->client($client)->set($prefName,$value);
	$log->debug("Param \"$prefName\" set.  ($value)");
	return(1);
}

sub _loadAllParams
{
	my($client)=@_;
	my $hashref={};

	# Gets all prefs, and puts them in the specified hashref...used for web interface page/module/handler...

	foreach my $key (sort(keys(%defaultConfigs))) {
		$hashref->{$key}=_getParam($client,$key);
	}


	return($hashref);
}

sub _saveAllParams
{
	my($client,$hashref)=@_;

	# Saves all prefs, from provided hashref...used for web interface page/module/handler...

	foreach my $key (sort(keys(%defaultConfigs))) {
		if(exists($hashref->{$key})) {
			if(!_setParam($client,$key,$hashref->{$key})) {
# XXX
			}
		} else {
			if(!_setParam($client,$key,$defaultConfigs{$key})) {
# XXX
			}
		}
	}

	return(1);
}

###############################################################################

sub _getCustomTemplateNames
{
	my($client)=@_;
	my $hashref={};

				# Get rid of the templates (in the options) we already know about, and re-add the list
				# fresh (incase any have been added/removed since we last got the list)
				my @templates=_loadCustomTemplates($_WEBLOGGER_PLAYING_TEMPLATE_DIR);
				foreach my $template (@templates) {
					$template=~/^(.*)(\.template(\..+)?)$/i;
					my $nicename=$1;
					$hashref->{weblogger_output_playing_template_options}{$template}=$nicename;
				}

				# ...and do the same for our STOPPED templates...
				my @templates=_loadCustomTemplates($_WEBLOGGER_STOPPED_TEMPLATE_DIR);
				foreach my $template (@templates) {
					$template=~/^(.*)(\.template(\..+)?)$/i;
					my $nicename=$1;
					$hashref->{weblogger_output_stopped_template_options}{$template}=$nicename;
				}

	return($hashref);
}

sub _loadCustomTemplates
{
	my($template_path)=@_;
	my @templates;

	# Gets a list of all song information templates from the appropriate templates
	# directory...

	# I'm not exactly sure what order this should be in, or even if this is the right/best way to do it?!
	# I don't understand "skins" concept in slim server yet!!!
	my $skinpath=Slim::Web::HTTP::fixHttpPath(preferences('server')->get('skin'),$template_path)
		|| Slim::Web::HTTP::fixHttpPath(Slim::Web::HTTP::baseSkin(),$template_path);

	$log->info("Reading template file list from \"$skinpath\" directory/folder.");

	# Read the template file listing from the templates directory...
	if(opendir(DIRFH, $skinpath)) {
		# We just want "xxx.template.xxx" files...
		@templates=grep { /\.template/ } readdir(DIRFH);
		closedir(DIRFH);
	} else {
		# Couldn't open directory...
	}

	# Return the filenames...
	return(@templates);
}

sub passEncrypt
{
	my($password)=@_;
	my $newpassword='';

	# Encrypts a password so that it is unreadable without some sort of processing...I realize
	# that this is not a GOOD encryption method or anything like that...and I know there's a
	# ton out there, but I didn't want to include a ton of modules...besides...this isn't
	# military information we're storing here, so as long as we make it "tricky" to decode...
	# that should be good enough...

	while(length($password)>0) {
		$newpassword.=sprintf('%X',ord(chop($password)));
	}

	return($newpassword);
}

sub passDecrypt
{
	my($password)=@_;
	my $newpassword='';

	# Undoes what the "encrypt" function does...(all really simple)...

	for(my $i=0;$i<length($password);$i+=2) {
		$newpassword=sprintf('%c',hex(substr($password,$i,2))).$newpassword;
	}

	return($newpassword);
}

sub changeStatusSetting
{
	my ($client,$value) = @_;

	# They've changed the status setting...store it...

	if($value) {
		# Being enabled...
		# (do nothing...let it update on the next song change)
	} else {
		# Being disabled...
		_killFTP($client);
	}

	_setParam($client,'weblogger_status',$value);
}

sub getFunctions
{
	my %functions = (
		'up' => sub  {
			my $client = shift;
			my $newposition = Slim::Buttons::Common::scroll($client, -1, ($#browseMenuChoices + 1), $active_client_list{$client->macaddress()}{activemenu});

			$active_client_list{$client->macaddress()}{activemenu}=$newposition;
			$client->update();
		},

		'down' => sub  {
			my $client = shift;
			my $newposition = Slim::Buttons::Common::scroll($client, +1, ($#browseMenuChoices + 1), $active_client_list{$client->macaddress()}{activemenu});

			$active_client_list{$client->macaddress()}{activemenu}=$newposition;
			$client->update();
		},

		'left' => sub  {
			my $client = shift;
			Slim::Buttons::Common::popModeRight($client);
		},

		'right' => sub  {
			my $client = shift;

			if ($browseMenuChoices[$active_client_list{$client->macaddress()}{activemenu}] eq $client->string('SETUP_UI_WEBLOGGER_ABOUT')) {

				# They want to enter the ABOUT sub-menu, so show it to them..
				my %params = (
					'header' => $client->string('SETUP_UI_WEBLOGGER_ABOUT'),
					'listRef' => [0],
					'externRef' => ['SETUP_UI_WEBLOGGER_ABOUT_INFO'],
					'stringExternRef' => 1,
				);
				Slim::Buttons::Common::pushModeLeft($client, 'INPUT.List',\%params);

			} elsif ($browseMenuChoices[$active_client_list{$client->macaddress()}{activemenu}] eq $client->string('SETUP_UI_WEBLOGGER_LAST_UPDATE')) {

				# They want to enter the ABOUT sub-menu, so show it to them..
				my %params = (
					'header' => $client->string('SETUP_UI_WEBLOGGER_LAST_UPDATE'),
					'listRef' => [0],
					'externRef' => [_getParam($client,'weblogger_last_update')],
					'stringExternRef' => 0,
				);
				Slim::Buttons::Common::pushModeLeft($client, 'INPUT.List',\%params);

			} elsif ($browseMenuChoices[$active_client_list{$client->macaddress()}{activemenu}] eq $client->string('SETUP_UI_WEBLOGGER_STATUS')) {

				# They want to enable, or disable weblogger for this client...
				my %params = (
					'header' => $client->string('SETUP_UI_WEBLOGGER_STATUS'),
					'listRef' => [0,1],
					'externRef' => ['SETUP_UI_WEBLOGGER_DISABLED','SETUP_UI_WEBLOGGER_ENABLED'],
					'stringExternRef' => 1,
					'valueRef' => _getParamRef($client,'weblogger_status'),
					'onChange' => \&changeStatusSetting
				);
				Slim::Buttons::Common::pushModeLeft($client, 'INPUT.List',\%params);

			}
		},
		'play' => sub {
			my $client = shift;

			if ($browseMenuChoices[$active_client_list{$client->macaddress()}{activemenu}] eq $client->string('SETUP_UI_WEBLOGGER_MANUAL_UPDATE')) {

				# They've hit the PLAY button while in the manual update menu...
				# ...they are trying to do a manual update now!

				# No song is currently playing...
				if(!doUpdate($client,undef,0,0)) {
					# There was an error, so display it...
					my $errorstring=$@;
					showFailure($client,$errorstring,0);
				} else {
					# Successfully updated as far as we can tell...
					showSuccess($client,'Update successful.',0);
				}

			} # else they're hitting play from another sub-menu within weblogger...
		}
	);

	return(\%functions);
}

sub _getTimestamp
{
	my($client)=@_;
	my $timestamp=Slim::Utils::DateTime::longDateF().' '.Slim::Utils::DateTime::timeF();
	return($timestamp);
}

sub _getAllLogItems
{
	my($client)=@_;
	my @logitems;
	my @checklist=qw(tracknum title duration composer album genre year artist conductor bitrate comment tagversion timestamp albumart playername webloggerversion);

	foreach my $key (@checklist) {
		if(uc(_getParam($client,'weblogger_log_'.$key))!=0) {
			push(@logitems,uc($key));
		}
	}

	return(@logitems);
}

sub getSongData
{
	my($client,$tempfileurl,$forlocaldisplayonly)=@_;
	my @logitems=_getAllLogItems($client);
	my %newinfo;

	# Load all of the information about this song that we've got, and might be using...

	# Make a new hash that we can manipulate without screwing up database data...
	# ('cause we need to add the timestamp, and who knows what else in the future)

	# Get the tag information that we want for the specified track/file, and store it in our hash...
	my $track=Slim::Schema->rs('Track')->objectForUrl($tempfileurl);

	foreach my $item (@logitems) {
		if($item eq 'TIMESTAMP') {
			$newinfo{$item}=_getTimestamp($client);
		} elsif($item eq 'ALBUMART') {
			# They've specified that they want the album art uploaded...
			# Add the graphic they've requested...
			my $albumart_filename=albumart_filename($client);

			# Load the selected album art...
			# (THIS IS A TOTAL HACK, BUT MY ONLY RECOURSE AFTER THE SERVER REFACTORING)
                        my $http_response=HTTP::Response->new;
                        my $imageData;
                        Slim::Web::Graphics::artworkRequest($client,"music/".$track->id."/".$albumart_filename,{},sub{ $imageData = $_[2] },undef,$http_response);
                        $imageData=$$imageData;
			if(defined($imageData)) {
				$newinfo{ALBUMART}=$imageData;

				# Set the URL in the hash so we know how to access it from HTML...
				if($forlocaldisplayonly) {
					$newinfo{ALBUMARTURL}="/music/".$track->id."/".$albumart_filename;
				} else {
					$newinfo{ALBUMARTURL}=_getParam($client,'weblogger_albumart_filename_prefix')._getParam($client,'weblogger_albumart_filename');
				}
			}

			# If no album art was retrieved (for whatever reason), then load the default...
			if((!$newinfo{ALBUMART})&&(_getParam($client,'weblogger_albumart_always'))) {
				# Load the default album art...
				$log->info("Loading default album art graphic file.");

				my $albumarttype=uc(_getParam($client,'weblogger_albumart_type'));

				# ...using default html template handlers...
				if($newinfo{ALBUMART}=${Slim::Web::HTTP::getStaticContent('plugins/WebLogger/html/images/_'.lc($albumarttype).'.jpg')}) {
					# Set the URL in the hash so we know how to access it from HTML...
					if($forlocaldisplayonly) {
						$newinfo{ALBUMARTURL}='/plugins/WebLogger/html/images/_'.lc($albumarttype).'.jpg';
					} else {
						$newinfo{ALBUMARTURL}=_getParam($client,'weblogger_albumart_filename_prefix')._getParam($client,'weblogger_albumart_filename');
					}
					$log->info("Default album art graphic file successfully loaded.");
				} else {
					$log->error("Default album art graphic file could not be loaded.");
				}
			}
		} elsif($item eq 'PLAYERNAME') {
			# The composer is returned as a list of objects, so let's turn it into what we really want...
			# (a simple string)
			$newinfo{$item}=$client->name();
		} elsif($item eq 'WEBLOGGERVERSION') {
			# The name and version of this plugin...
			$newinfo{$item}=$client->string('PLUGIN_WEBLOGGER_UI_TITLE')." v$VERSION";
		} elsif($item eq 'COMPOSER') {
			$newinfo{$item}=(($track->contributorsOfType('COMPOSER')->single)?$track->contributorsOfType('COMPOSER')->single->name:'');
		} elsif($item eq 'ARTIST') {
			$newinfo{$item}=(($track->artist)?$track->artist->name:'');
		} elsif($item eq 'ALBUM') {
			$newinfo{$item}=(($track->album)?$track->album->name:'');
		} elsif($item eq 'GENRE') {
			$newinfo{$item}=(($track->genre)?$track->genre->name:'');
		} elsif($item eq 'BITRATE') {
			$newinfo{$item}=($track->bitrate/1000).'kbps';
		} else {
			if(my $codeptr=$track->can(lc($item))) {
				# Set it with an sprintf so we don't end up with an object, but always as it's string representation...
				my $temp=&$codeptr($track);
				$newinfo{$item}=sprintf('%s',$temp || '');
			} else {
				$log->error("Track data \"".lc($item)."\" could not be retrieved...object method does not exist.");
			}
		}
	}

	# This function is only called for a song that's playing, so our status is easy...
	$newinfo{STATUS}='PLAYING';

	return(\%newinfo);
}

sub getStoppedData
{
	my($client,$forlocaldisplayonly)=@_;
	my @logitems=_getAllLogItems($client);
	my %newinfo;

	# Returns the data for when the player is stopped/not playing anything...

	foreach my $item (@logitems) {
		if($item eq 'TIMESTAMP') {
			$newinfo{$item}=_getTimestamp($client);
		} elsif($item eq 'ALBUMART') {
			# They've specified that they want the album art uploaded...
			# Add the graphic they've requested...
			my $albumarttype=uc(_getParam($client,'weblogger_albumart_type'));

			$log->info("Loading default playback stopped graphic file.");

			# ...using default html template handlers...
			if($newinfo{ALBUMART}=${Slim::Web::HTTP::getStaticContent('plugins/WebLogger/html/images/_'.lc($albumarttype).'_stopped.jpg')}) {
				# Set the URL in the hash so we know how to access it from HTML...
				if($forlocaldisplayonly) {
					$newinfo{ALBUMARTURL}='/plugins/WebLogger/html/images/_'.lc($albumarttype).'_stopped.jpg';
				} else {
					$newinfo{ALBUMARTURL}=_getParam($client,'weblogger_albumart_filename_prefix')._getParam($client,'weblogger_albumart_filename');
				}
				$log->info("Default playback stopped graphic file successfully loaded.");
			} else {
				$log->error("Default playback stopped graphic file could not be loaded.");
			}
		} elsif($item eq 'PLAYERNAME') {
			# The composer is returned as a list of objects, so let's turn it into what we really want...
			# (a simple string)
			$newinfo{$item}=$client->name();
		} elsif($item eq 'WEBLOGGERVERSION') {
			# The name and version of this plugin...
			$newinfo{$item}=$client->string('PLUGIN_WEBLOGGER_UI_TITLE')." v$VERSION";
		} # else it's not supported as "stopped" data...
	}

	# This function is only called for a song that's playing, so our status is easy...
	$newinfo{STATUS}='STOPPED';

	return(\%newinfo);
}

sub doUpdate
{
	my($client,$currentlyplayingurl,$onlyifchanged,$ispowerdown)=@_;

	# Performs an update of the currently playing song, and/or stopped information...
	# (if $currentlyplayingurl is passed in, it is used...otherwise, it is gotten automatically)

	# Check for whether this plugin is enabled ELSEWHERE (before this call), because we
	# need to use this for manual updates as well...

	if($currentlyplayingurl) {
		# If we're passed in the URL, then that's the song that's playing...
		# Get all of the song information that is selected for updating...
		my $songinfo=getSongData($client,$currentlyplayingurl,0);
		if(!_reallyUpdate($client,$songinfo,$onlyifchanged)) {
			return(_errorOut($@));
		}
	} elsif(((Slim::Player::Source::playmode($client) eq 'stop')||($ispowerdown))&&(_getParam($client,'weblogger_output_stopped_file_enabled'))) {
		# No song is currently playing, or the client/player is powered down, and we want
		# the "stopped" information logged too...
		my $songinfo=getStoppedData($client,0);
		if(!_reallyUpdate($client,$songinfo,$onlyifchanged)) {
			return(_errorOut($@));
		}
	} elsif((Slim::Player::Source::playmode($client) eq 'stop')||($ispowerdown)) {
		# No song is currently playing, or the client/player is powered down, but we don't
		# want that logged, so error out...
		return(_errorOut("Nothing currently playing."));

	} else {	# Slim::Player::Source::playmode($client) eq 'play' (most likely)
		# We're probably playing a song, but it wasn't provided, so we need to get
		# it ourselves...
		# Get the currently playing song by magical craziness...
		if(!($currentlyplayingurl=$client->playlist->[$client->shufflelist->[$client->currentsongqueue->[0]->index]])) {
			# We couldn't get the currently playing track...
			return(_errorOut("Current playlist is empty."));
		}	# else we've got the currently playing song url...

		# Get all of the song information that is selected for updating...
		my $songinfo=getSongData($client,$currentlyplayingurl,0);
		if(!_reallyUpdate($client,$songinfo,$onlyifchanged)) {
			return(_errorOut($@));
		}
	}

	return(1);
}

sub _errorOut
{
	my($errormessage)=@_;
	$@=$errormessage;
	return(0);
}

sub parseSubmissionURL
{
	my($url)=@_;
	my %paramlist;

	# Breaks a URL down into the actual URL, and any params that might be in there...
	# (returns them seperated as a STRING, and HASHREF)

	if($url=~/(.*)\?([^?]+)/) {
		my $params;
		($url,$params)=($1,$2);
		foreach my $paramstring (split(/[?&]+/,$params)) {
			if($paramstring=~/^([^=]*)=([^=]*)$/) {
				$paramlist{$1}=uri_unescape($2);
			}
		}
	}
	return($url,\%paramlist);
}

sub getPlayingSongTemplate
{
	my($client,$songinfo)=@_;
	my $containsfiles=0;

	# Gets our template all ready for transmission...

	my $template_filename=_getParam($client,'weblogger_output_playing_template');

	# If this file type can package up, and include the raw graphic data, we need to know...
	# (so we don't send the graphic twice)
	if($template_filename=~/\.xml$/) {
		$containsfiles=1;
	}

	# Get our "file" contents ready for output...
	my $templateref=Slim::Web::HTTP::filltemplatefile($_WEBLOGGER_PLAYING_TEMPLATE_DIR.'/'.$template_filename,{SONG => $songinfo});
	my $output=$$templateref;

	$log->debug("Playing song template successfully retrieved -> ".$output);

	return($output,$containsfiles);
}

sub getStoppedTemplate
{
	my($client,$songinfo)=@_;
	my $containsfiles=0;

	# Gets our template all ready for transmission...

	my $template_filename=_getParam($client,'weblogger_output_stopped_template');

	# If this file type can package up, and include the raw graphic data, we need to know...
	# (so we don't send the graphic twice)
	if($template_filename=~/\.xml$/) {
		$containsfiles=1;
	}

	# Get our "file" contents ready for output...
	my $templateref=Slim::Web::HTTP::filltemplatefile($_WEBLOGGER_STOPPED_TEMPLATE_DIR.'/'.$template_filename,{SONG => $songinfo});
	my $output=$$templateref;

	$log->debug("Stopped template successfully retrieved -> ".$output);

	return($output,$containsfiles);
}

sub _storeSongInfo
{
	my($client,$songinfo)=@_;

	# Stores the song information (minus the timestamp) we've just updated
	# with so that we can check to see if it's changed on the next update
	# attempt...('cause if it's the same, we shouldn't bother then)

	$active_client_list{$client->macaddress()}{lastsonginfo}={};
	foreach my $key (keys(%$songinfo)) {
		next if($key eq 'TIMESTAMP');
		$active_client_list{$client->macaddress()}{lastsonginfo}{$key}=$songinfo->{$key};
	}
}

sub _songInfoChanged
{
	my($client,$songinfo)=@_;

	# Checks to see if the song information we're going to update to is different from what was written on the last update...
	# (ignoring the TIMESTAMP field as that changes every second)

	$active_client_list{$client->macaddress()}{lastsonginfo}={} if(!exists($active_client_list{$client->macaddress()}{lastsonginfo}));
	foreach my $key (keys(%$songinfo)) {
		next if($key eq 'TIMESTAMP');
		if((!exists($active_client_list{$client->macaddress()}{lastsonginfo}{$key}))||($songinfo->{$key} ne $active_client_list{$client->macaddress()}{lastsonginfo}{$key})) {
			return(1);
		}
	}

	# Nothing's changed...it looks the same...
	return(0);
}

sub _reallyUpdate
{
	my($client,$songinfo,$onlyifchanged)=@_;

	# Stores the song info on the specified server...

	# If nothing's changed since the last update...don't bother updating again...
	if(($onlyifchanged)&&(!_songInfoChanged($client,$songinfo))) {
		# Nothing's changed...skip the update...
		return(1);
	}

	# Display text temporarily to let them know why it's paused (if it has at all)...
	# (No need to display this above, 'cause we only get here if something's changed)
	showSuccess($client,'Updating song information...',0);

	# Make a list of files to upload (we already have them in memory, so we have to fudge some stuff)
	my (%files,$songfile,$containsfiles)=();
	if($songinfo->{STATUS} eq 'STOPPED') {
		# There's no song playing...our data says so...
		($songfile,$containsfiles)=getStoppedTemplate($client,$songinfo);
		$files{_getParam($client,'weblogger_output_filename')}=$songfile;
		$files{_getParam($client,'weblogger_albumart_filename')}=$songinfo->{ALBUMART} if((exists($songinfo->{ALBUMART}))&&(defined($songinfo->{ALBUMART}))&&(!$containsfiles));

	} else {
		# We've got the data of the currently playing song...
		($songfile,$containsfiles)=getPlayingSongTemplate($client,$songinfo);
		$files{_getParam($client,'weblogger_output_filename')}=$songfile;
		$files{_getParam($client,'weblogger_albumart_filename')}=$songinfo->{ALBUMART} if((exists($songinfo->{ALBUMART}))&&(defined($songinfo->{ALBUMART}))&&(!$containsfiles));
	}

	# Get our submission URL, and vars to pass in, and do it...
	my $url=_getParam($client,'weblogger_storage_url');

	# We need a timeout incase an update takes forever...
	# (we can't use ALARM because something else uses it within LWP, and it cancels our out)
	my $TIMEOUT=uc(_getParam($client,'weblogger_update_timeout'));

	if($url=~/^ftp:\/\//i) {
		# Send file to FTP site...
		if(!_updateByFTP($client,$url,\%files,$TIMEOUT)) {
			return(_errorOut($@));
		}
	} elsif($url=~/^https?:\/\//i) {
		# Submit as HTTP GET/POST to a script...
		my $method=uc(_getParam($client,'weblogger_http_method'));

		# Rip out all specified params from the URL...
		my $paramlist;
		($url,$paramlist)=parseSubmissionURL($url);

		# Add song information if it's not to be sent as a file type...
		# Add the one hash to the other...now we're ready to submit...
		foreach my $infokey (keys(%$songinfo)) {
			next if($infokey=~/^ALBUMART/);
			$paramlist->{$infokey}=$songinfo->{$infokey};
		}

		if($method eq 'MULTIPARTPOST') {
			# POST as params AND files...
			if(!_updateByHTTPMultipartPost($client,$url,{%$paramlist, %files},$TIMEOUT)) {
				return(_errorOut($@));
			}
		} elsif($method eq 'POST') {
			# If they want the graphic sent...return an error because there's no way to do it via GET...
			if((exists($songinfo->{ALBUMART}))&&(defined($songinfo->{ALBUMART}))) {
				return(_errorOut("Album art upload via standard POST not possible.  (Use \"multipart post\" instead)"));
			}

			# POST just params...
			if(!_updateByHTTPPost($client,$url,$paramlist,$TIMEOUT)) {
				return(_errorOut($@));
			}
		} elsif($method eq 'GET') {
			# If they want the graphic sent...return an error because there's no way to do it via GET...
			if((exists($songinfo->{ALBUMART}))&&(defined($songinfo->{ALBUMART}))) {
				return(_errorOut("Album art upload via GET not possible.  (Use \"multipart post\" instead)"));
			}

			# GET just params...
			if(!_updateByHTTPGet($client,$url,$paramlist,$TIMEOUT)) {
				return(_errorOut($@));
			}
		} else {
			return(_errorOut("Unknown HTTP method specified in config.  ($method)"));
		}
	} else {
		# Text file output...
		if(!_updateByLocalFile($client,$url,\%files,$TIMEOUT)) {
			return(_errorOut($@));
		}
	}

	# The update is done...keep track of the songinfo to minimize un-necessary updates...
	_storeSongInfo($client,$songinfo);

	# Store our "last successful update" timestamp...
	_setParam($client,'weblogger_last_update',_getTimestamp($client));

	# All is well...we're done...
	return(1);	
}

sub _setFTPKeepAliveTimer
{
	my($client,$server,$username,$password,$filepath)=@_;
	my $_MINIMUM=15;
	my $_MAXIMUM=60;
	my $timerval=$_MINIMUM+rand($_MAXIMUM-$_MINIMUM);

	# Just sets the keep alive timer to a semi-random value so we can
	# keep the ftp connection open...

	Slim::Utils::Timers::setTimer($client, (Time::HiRes::time() + $timerval), \&_keepFTPAlive, $server, $username, $password, $filepath);
}

sub _keepFTPAlive
{
	my($client,$server,$username,$password,$filepath)=@_;

	# Send a command to the FTP server so it doesn't think we've fallen asleep...
	# The _loginFTP function does this for us, so let's just use that...
	# PLUS...if we're not logged in (for whatever reason), it will make sure we do...

	# Get our keep alive settings (including dummy file filename)...
	my $keepalive=uc(_getParam($client,'weblogger_ftp_keepalive'));
	my $dummyfile=_getParam($client,'weblogger_ftp_dummyfile');

	# Not fussy...
	if($keepalive eq 'ANY') {
		# Pick a random one out of the list...
		my @random_keepalive_types=qw(UPLOADDUMMY DOWNLOADDUMMY DOWNLOADSONGINFO COMMANDS);
		$keepalive=$random_keepalive_types[rand(scalar(@random_keepalive_types))];
	}

	# Just incase we got here by some wierd mistake?!
	if($keepalive eq 'DISABLED') {
		return;
	}

# XXX - If any of these fail because the connection has closed...re-open the thing then...
# XXX - Log each of these, so we know what's going on when logging is turned on!?

	eval {
		local $SIG{ALRM}=sub{die "Keep alive time of 2 seconds exceeded"};
		alarm(2);
		if((exists($active_client_list{$client->macaddress()}{openftp}))&&(defined($active_client_list{$client->macaddress()}{openftp}))) {
			# Alright...we have an FTP object, and should be logged in...
			if($keepalive eq 'COMMANDS') {
				my @random_keepalive_commands=('pwd','rest 0','type i','type a','noop','dir','ls');	# ,'list','stat'
				my $command_to_send=$random_keepalive_commands[rand(scalar(@random_keepalive_commands))];
				$active_client_list{$client->macaddress()}{openftp}->quot($command_to_send);
			} elsif($keepalive eq 'UPLOADDUMMY') {
				my $tempfile; # Asking for undef doesn't actually open the file...it just gives us a temp filename to use. 
				(undef,$tempfile)=File::Temp::tempfile();

				# Write to our temporary file...
				if(open(TEMPFILEFH,"> $tempfile")) {
					print TEMPFILEFH $dummyfile;
					close(TEMPFILEFH);
				}

				# Now send the dummy file to the FTP site, but name it properly...
				if(!$active_client_list{$client->macaddress()}{openftp}->put($tempfile,$dummyfile)) {
					die($active_client_list{$client->macaddress()}{openftp}->message());
				}

				# We're done with our temporary file...
				unlink($tempfile);
			} elsif($keepalive eq 'DOWNLOADDUMMY') {
				my $tempfile; # Asking for undef doesn't actually open the file...it just gives us a temp filename to use. 
				(undef,$tempfile)=File::Temp::tempfile();

				# Now get the dummy file from the FTP site...
				if(!$active_client_list{$client->macaddress()}{openftp}->get($dummyfile,$tempfile)) {
					die($active_client_list{$client->macaddress()}{openftp}->message());
				}

				# We're done with our temporary file...
				unlink($tempfile);
			} elsif($keepalive eq 'DOWNLOADSONGINFO') {
				my $tempfile; # Asking for undef doesn't actually open the file...it just gives us a temp filename to use. 
				(undef,$tempfile)=File::Temp::tempfile();

				# Now get the song information file from the FTP site...
				if(!$active_client_list{$client->macaddress()}{openftp}->get(_getParam($client,'weblogger_output_filename'),$tempfile)) {
					die($active_client_list{$client->macaddress()}{openftp}->message());
				}

				# We're done with our temporary file...
				unlink($tempfile);
			}
		}
		alarm(0);
	};

	if($@) {
		# We need to clear this out so slim server's internal timer stuff doesn't choke...
		alarm(0);
		$log->debug("_keepFTPAlive(): $@");
	}

	# Gotta come back and do this again in a bit...
	_setFTPKeepAliveTimer($client, $server, $username, $password, $filepath);
}

sub _loginFTP
{
	my($client,$server,$username,$password,$filepath)=@_;

	# Opens our FTP session, and navigates us to the directory where we need to send the files...
	# (caches the connection if the keepalive flag is set for fast updates)

	if((exists($active_client_list{$client->macaddress()}{openftp}))&&(defined($active_client_list{$client->macaddress()}{openftp}))) {
		# FTP should still be alive!?  (what if we were kicked out?!)
		# Test to see if we're still logged in by issuing a useless command...
		if($active_client_list{$client->macaddress()}{openftp}->cwd($filepath)) {
			# Return our working FTP handle..
			return($active_client_list{$client->macaddress()}{openftp});
		} # else we were disconnected...so continue on, so we can login again...
	}

	# If we've made it here...we need to create an FTP session, and login with the provided info...
	$active_client_list{$client->macaddress()}{openftp}=Net::FTP->new($server,
		Passive => _getParam($client,'weblogger_ftp_passive'),
		Debug => $_DEBUG,
		# Timeout => 1200
		);


	if(!$active_client_list{$client->macaddress()}{openftp}) {
		die("Bad server: $server");
	}

	# Login without our specified info...
	if(!$active_client_list{$client->macaddress()}{openftp}->login($username,$password)) {
		die($active_client_list{$client->macaddress()}{openftp}->message());
	}

	# Go to the specified sub-directory...
	if(($filepath)&&(!$active_client_list{$client->macaddress()}{openftp}->cwd($filepath))) {
		die($active_client_list{$client->macaddress()}{openftp}->message());
	}

	# Successful...return the object for use...
	return($active_client_list{$client->macaddress()}{openftp});
}

sub _logoutFTP
{
	my($client)=@_;

	# Logs out, and kills our FTP session unless the keepalive flag is set...

	if((!exists($active_client_list{$client->macaddress()}{openftp}))||(!defined($active_client_list{$client->macaddress()}{openftp}))) {
		# No ftp connection, so don't bother logging out...
		return;
	}

	if(_getParam($client,'weblogger_ftp_keepalive') ne 'DISABLED') {
		# They want to keep the FTP connection alive...so don't quit...
		# (leave it open, and ready for the next call)
		return;
	}

	# We're done with FTP...log out nicely...
	if(!$active_client_list{$client->macaddress()}{openftp}->quit()) {
# XXX
#		die($active_client_list{$client->macaddress()}{openftp}->message());
		$log->debug("Could not QUIT: ".$active_client_list{$client->macaddress()}{openftp}->message());
	}

	# We don't undef the reference to the FTP object, because it helps GREATLY for
	# speed if we don't have to re-init a new FTP object everytime...
	# (I'm not sure why because we're doing a "new" everytime...but oh well...)
	# $active_client_list{$client->macaddress()}{openftp}=undef;

	return;
}

sub _killFTP
{
	my($client)=@_;

	# Function to force the closing of our FTP connection, and stopping
	# our KEEP-ALIVE action from taking place...should be called upon client
	# power-down and/or stop...

	# Kill off current timer (if any)...
	Slim::Utils::Timers::killTimers($client,\&_keepFTPAlive);

	if((!exists($active_client_list{$client->macaddress()}{openftp}))||(!defined($active_client_list{$client->macaddress()}{openftp}))) {
		# No ftp connection, so don't bother logging it out or killing it...
		return;
	}

	# We're done with FTP...log out nicely...
	if(!$active_client_list{$client->macaddress()}{openftp}->quit()) {
# XXX
#		die($active_client_list{$client->macaddress()}{openftp}->message());
		$log->debug("Could not QUIT: ".$active_client_list{$client->macaddress()}{openftp}->message());
	}

	# We don't undef the reference to the FTP object, because it helps GREATLY for
	# speed if we don't have to re-init a new FTP object everytime...
	# (I'm not sure why because we're doing a "new" everytime...but oh well...)
	# $active_client_list{$client->macaddress()}{openftp}=undef;

	return;
}

sub _updateByHTTPMultipartPost
{
	my($client,$url,$paramlist,$timeout)=@_;

	# Prepare our HTTP request...
	my $request=POST $url, Content_Type => 'form-data', Content => [%$paramlist];

	# Create our UserAgent, and send the file/params...
	# (submit our faked "form" data)
	my $ua = LWP::UserAgent->new;
	$ua->parse_head(0);	# Slimserver does not include the HTML::HeadeParser module(s)...
	$ua->timeout($timeout);
	my $response=$ua->simple_request($request);
	if($response->is_error()) {
		my $errorCode=$response->code;
		my $errorMessage=$response->message;
		$errorMessage='Connection timed out.' if(($errorCode==500)&&(!$errorMessage));
		return(_errorOut("$errorMessage (#$errorCode)"));
	}

	# Check for, and return an error, or continue on if successful...
	my $content=$response->content;
	if((_getParam($client,'weblogger_http_checkforok'))&&($content!~/^OK/)) {
		return(_errorOut($content));
	}

	return(1);
}

sub _updateByHTTPPost
{
	my($client,$url,$paramlist,$timeout)=@_;

	# Prepare our HTTP request...
	my $request=POST $url, [%$paramlist];

	# Create our UserAgent, and send the file/params...
	# (submit our faked "form" data)
	my $ua = LWP::UserAgent->new;
	$ua->parse_head(0);	# Slimserver does not include the HTML::HeadeParser module(s)...
	$ua->timeout($timeout);
	my $response=$ua->simple_request($request);
	if($response->is_error()) {
		my $errorCode=$response->code;
		my $errorMessage=$response->message;
		$errorMessage='Connection timed out.' if(($errorCode==500)&&(!$errorMessage));
		return(_errorOut("HTTP Error #$errorCode: $errorMessage"));
	}

	# Check for, and return an error, or continue on if successful...
	my $content=$response->content;
	if((_getParam($client,'weblogger_http_checkforok'))&&($content!~/^OK/)) {
		return(_errorOut($content));
	}

	return(1);
}

sub _updateByHTTPGet
{
	my($client,$url,$paramlist,$timeout)=@_;

	# Rebuild URL with the params that have been added to etc...
	$url.='?';
	foreach my $key (keys(%$paramlist)) {
		$url.=$key."=".uri_escape($paramlist->{$key})."&";
	}

	# Prepare our HTTP request...
	my $request=GET $url;

	# Create our UserAgent, and send the file/params...
	# (submit our faked "form" data)
	my $ua = LWP::UserAgent->new;
	$ua->parse_head(0);	# Slimserver does not include the HTML::HeadeParser module(s)...
	$ua->timeout($timeout);
	my $response=$ua->simple_request($request);
	if($response->is_error()) {
		my $errorCode=$response->code;
		my $errorMessage=$response->message;
		$errorMessage='Connection timed out.' if(($errorCode==500)&&(!$errorMessage));
		return(_errorOut("$errorMessage (#$errorCode)"));
	}

	# Check for, and return an error, or continue on if successful...
	my $content=$response->content;
	if((_getParam($client,'weblogger_http_checkforok'))&&($content!~/^OK/)) {
		return(_errorOut($content));
	}

	return(1);
}

sub _updateByFTP
{
	my($client,$url,$files,$timeout)=@_;

	# Rips the specified URL apart into the bits we need...
	my ($server,$filepath)=();
	if($url=~/^ftp:\/\/([^\\\/]*)([\\\/].*)?[\\\/]?$/i) {
		$server=uri_unescape($1 || '');
		$filepath=uri_unescape($2 || '');
	} else {
		return(_errorOut("Bad URL: $url"));
	}

	# Get our login info...
	my $username=_getParam($client,'weblogger_ftp_username');
	my $password=passDecrypt(_getParam($client,'weblogger_ftp_password'));

	# Kill off current timer (if any)...
	Slim::Utils::Timers::killTimers($client,\&_keepFTPAlive);

	# Let's do the actual FTP now that we have our info...
	my $ftp;
	eval
	{
		# Set the timer...
		local $SIG{ALRM}=sub{die "$timeout second limit reached"};
		alarm($timeout);

		# Get our FTP object to where we need to be logged in...
		my $ftp=_loginFTP($client,$server,$username,$password,$filepath);

		# Let's just send everything as a binary type...the worst that can happen is
		# extra/missing CR/LF characters depending what type of machine we're transferring between...
                if(!$ftp->binary()) {
                        die($ftp->message());
                }

		foreach my $filename (keys(%$files)) {
			my $tempfile; # Asking for undef doesn't actually open the file...it just gives us a temp filename to use. 
			(undef,$tempfile)=File::Temp::tempfile();

			# Write to our temporary file...
			if(open(TEMPFILEFH,"> $tempfile")) {
				binmode TEMPFILEFH;
				print TEMPFILEFH $files->{$filename};
				close(TEMPFILEFH);
			}

			# Now send the temporary file to the FTP site, but name it properly...
			if(!$ftp->put($tempfile,$filename)) {
				die($ftp->message());
			}

			# We're done with our temporary file...
			unlink($tempfile);
		}

		# We're done with FTP (for now)...
		_logoutFTP($client);

		# Kill the timer...
		alarm(0);
	};

	# We need to do this because we are setting the timer in-between...
	# (it screws up $@)
	my $ftpError=$@;

	# Error or not...
	if(_getParam($client,'weblogger_ftp_keepalive') ne 'DISABLED') {
		# Make sure we keep the FTP connection alive...
		_setFTPKeepAliveTimer($client, $server, $username, $password, $filepath);
	}

	if($ftpError) {

		# We need to kill the timer just incase we died out, and skipped the reset...
		# Otherwise, the timer could still go off, and cause the server to die...
		alarm(0);
		return(_errorOut("$ftpError"));
	}

	return(1);
}

sub _updateByLocalFile
{
	my($client,$url,$files,$timeout)=@_;

	# Get rid of the file:// if any...
	my($filepath)=();
	if($url=~/^file:\/\/(.*)[\\\/]?/) {
		$filepath=$1 || '';
	} else {
		return(_errorOut("Could not parse specified URL.  ($url)"));
	}

	foreach my $filename (keys(%$files)) {
		# Write out file...
		if(open(FILEOUTPUTFH,"> $filepath/$filename")) {
			binmode FILEOUTPUTFH;
			print FILEOUTPUTFH $files->{$filename};
			close(FILEOUTPUTFH);
		} else {
			return(_errorOut("Could not write to \"$filepath/$filename\"."));
		}
	}

	return(1);
}

###############################################################################

sub webPages {
        my $class = shift;

        Slim::Web::Pages->addPageFunction('plugins/WebLogger/preview_stopped_template.html', \&handleStoppedPreview);
        Slim::Web::Pages->addPageFunction('plugins/WebLogger/preview_playing_template.html', \&handlePlayingPreview);
        Slim::Web::Pages->addPageFunction('plugins/WebLogger/manual_update.html', \&handleUpdate);
}

sub handlePlayingPreview
{
	my ($client_playing, $params) = @_;
	my $client_config=Slim::Player::Client::getClient($params->{playerid});
	my $client=$client_config || $client_playing;

	# Get the URL of the song at the top of the current playlist...
	# (the one playing, or the next one that will be played)
	my $currentlyplayingurl=undef;
	if(($client)&&($client->playlist)&&($client->shufflelist)) {
		# We should have a song URL...
		# Get the currently playing song by magical craziness...
		$currentlyplayingurl=$client->playlist->[$client->shufflelist->[$client->currentsongqueue->[0]->index]];
	}

	# We need some sample song data to display in examples and stuff...
	if($currentlyplayingurl) {
		# Add this song's information so it can be used for example display...
		my $songinfo=getSongData($client,$currentlyplayingurl,1);
		foreach my $key (keys(%$songinfo)) {
			$params->{SONG}{$key}=$songinfo->{$key};
		}

		# Oust the graphic data, or the display will be screwed!!!
		$params->{SONG}{ALBUMART}='*** GRAPHIC DATA ***';

	} else {
		# There is no song in the list...make up test data...
		$params->{SONG}{TITLE}='American Woman';
		$params->{SONG}{ARTIST}='The Guess Who';
		$params->{SONG}{ALBUM}='Greatest Hits';
		$params->{SONG}{TIMESTAMP}=_getTimestamp($client);
		$params->{SONG}{ALBUMART}='*** GRAPHIC DATA ***';
		$params->{SONG}{ALBUMARTURL}='/plugins/WebLogger/html/images/_'.lc(_getParam($client,'weblogger_albumart_type')).'.jpg';
	}

	# Show the main WebLogger config webpage...
	# (it is our only page for now)
	my $template=Slim::Web::HTTP::filltemplatefile('plugins/WebLogger/preview_playing_template.html',$params);
	return($template);
}

sub handleStoppedPreview
{
	my ($client_playing, $params) = @_;
	my $client_config=Slim::Player::Client::getClient($params->{playerid});
	my $client=$client_config || $client_playing;

	# Add this song's information so it can be used for example display...
	my $songinfo=getStoppedData($client,1);
	foreach my $key (keys(%$songinfo)) {
		$params->{SONG}{$key}=$songinfo->{$key};
	}

	# Oust the graphic data, or the display will be screwed!!!
	$params->{SONG}{ALBUMART}='*** GRAPHIC DATA ***';

	# Show the main WebLogger config webpage...
	# (it is our only page for now)
	my $template=Slim::Web::HTTP::filltemplatefile('plugins/WebLogger/preview_stopped_template.html',$params);
	return($template);
}

sub handleUpdate
{
	my ($client_playing, $params) = @_;
	my $client_config=Slim::Player::Client::getClient($params->{playerid});
	my $client=$client_config || $client_playing;

	# There is no client object...what are we supposed to configure???  Nothing!
	if((!$client)||(!isValidClient($client))) {
		$params->{status}='ERROR';
		$params->{status_message}='Invalid player/client.';
	} else {
		# Get the URL of the song at the top of the current playlist...
		# (the one playing, or the next one that will be played)

		# We want to do a manual update...
		if(!doUpdate($client,undef,0,0)) {
			# There was an error, so display it...
			$params->{status}='ERROR';
			$params->{status_message}=$@;
		} else {
			# The update went perfectly...
			$params->{status}='OK';
			$params->{status_message}='Updated successfully.';
		}
	}

	# Return page containing the status of the update...to be displayed in the iframe on the page...
	my $template=Slim::Web::HTTP::filltemplatefile('plugins/WebLogger/manual_update_status.html',$params);
	return($template);
}

sub albumart_filename {
	my($client)=@_;
	my $filename;

	# Returns the filename for the selected albumart type...

	my $albumarttype=uc(_getParam($client,'weblogger_albumart_type'));
	if($albumarttype eq 'THUMB') {
		$filename='cover_75x75.jpg';
	} else {
		$filename='cover_200x200.jpg';
	}

	return($filename);
}

1;
