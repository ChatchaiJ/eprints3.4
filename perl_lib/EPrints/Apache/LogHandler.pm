######################################################################
#
# EPrints::Apache::LogHandler
#
######################################################################
#
#
######################################################################

=pod

=for Pod2Wiki

=head1 NAME

EPrints::Apache::LogHandler - Main handler for Apache log events

=head1 CONFIGURATION

To enable the Apache::LogHandler add to your ArchiveConfig:

   $c->{loghandler}->{enable} = 1;

=head1 DATA FORMAT

=over 4

=item requester

The requester is stored using their IP in URN format: C<urn:ip:x.x.x.x>.

=item serviceType

ServiceType is in format L<info:ofi/fmt:kev:mtx:sch_svc|http://alcme.oclc.org/openurl/servlet/OAIHandler?verb=GetRecord&metadataPrefix=oai_dc&identifier=info:ofi/fmt:kev:mtx:sch_svc>.

The value is encoded as C<?name=yes> (where C<name> is one of the services defined).

=item referent, referringEntity

These are stored in URN format: C<info:oai:repositoryid:eprintid>.

=item referent_docid

The document id as a fragment of the referent: C<#docid>.

=back

=head1 METHODS

=cut

package EPrints::Apache::LogHandler;

use EPrints;

use strict;

use EPrints::Apache::AnApache;
use Apache2::Connection;

our @USERAGENT_ROBOTS = map { qr/$_/i } qw{
	Alexandria(\s|\+)prototype(\s|\+)project
	Arachmo
	Brutus\/AET
	Code(\s|\+)Sample(\s|\+)Web(\s|\+)Client
	dtSearchSpider
	FDM(\s|\+)1
	Fetch(\s|\+)API(\s|\+)Request
	GetRight
	Goldfire(\s|\+)Server
	Googlebot
	httpget\−5\.2\.2
	HTTrack
	iSiloX
	libwww\-perl
	LWP\:\:Simple
	lwp\-trivial
	Microsoft(\s|\+)URL(\s|\+)Control
	Milbot
	MSNBot
	NaverBot
	Offline(\s|\+)Navigator
	playstarmusic.com
	Python\-urllib
	Readpaper
	Strider
	T\-H\-U\-N\-D\-E\-R\-S\-T\-O\-N\-E
	Teleport(\s|\+)Pro
	Teoma
	Web(\s|\+)Downloader
	WebCloner
	WebCopier
	WebReaper
	WebStripper
	WebZIP
	Wget
	Xenu(\s|\+)Link(\s|\+)Sleuth
};
our %ROBOTS_CACHE; # key=IP, value=time (or -time if not a robot)
our $TIMEOUT = 3600; # 1 hour

######################################################################
=pod

=over 4

=item EPrints:Apache::LogHandler::handler

Empty (as deprecated)  handler method.

=cut
######################################################################

sub handler {}

######################################################################
=pod

=item EPrints:Apache::LogHandler::is_robot( $r, $ip )

Test if request $r is a robot based on I<User-Agent> or if $ip is
listed as a robot.

Returns boolean dependent or whether request has determined to be a 
robot.

=cut
######################################################################

sub is_robot
{
	my( $r, $ip ) = @_;

	my $time_t = time();

	# cleanup then check the cache
	for(keys %ROBOTS_CACHE)
	{
		delete $ROBOTS_CACHE{$_} if abs($ROBOTS_CACHE{$_}) < $time_t;
	}

	return $ROBOTS_CACHE{$ip} > 0 if exists $ROBOTS_CACHE{$ip};
	$ROBOTS_CACHE{$ip} = $time_t + $TIMEOUT;

	my $is_robot = 0;

	my $ua = $r->headers_in->{ "User-Agent" };
	if( $ua )
	{
		for(@USERAGENT_ROBOTS)
		{
			$is_robot = 1, last if $ua =~ $_;
		}
	}

	$ROBOTS_CACHE{$ip} *= -1 if !$is_robot;

	return $is_robot;
}

######################################################################
=pod

=item $handler->document( $r )

A request on a document.

=cut
######################################################################

sub document
{
	my( $r ) = @_;

	# COUNTER compliance specifies 200 and 304
	if( $r->status != 200 && $r->status != 304 )
	{
		return DECLINED;
	}

	my $doc = $r->pnotes( "document" );

	my $ip = $doc->repository->remote_ip;
	return if is_robot( $r, $ip );

	my $filename = $r->pnotes->{ "filename" };

	# only count hits to the main file
	if( $filename ne $doc->get_main )
	{
		return DECLINED;
	}

	# ignore volatile version downloads (e.g. thumbnails)
        my $relations = $doc->get_value( "relation" );
        $relations = [] unless( defined $relations );
        foreach my $r (@$relations)
        {
                return DECLINED if( $r->{type} =~ /is\w+ThumbnailVersionOf$/ );
        }

	my $epdata = _generic( $r, { _parent => $doc } );

	$epdata->{requester_id} = $ip;
	$epdata->{service_type_id} = "?fulltext=yes";
	$epdata->{referent_id} = $doc->value( "eprintid" );
	$epdata->{referent_docid} = $doc->id;

	return _create_access( $r, $epdata );
}

######################################################################
=pod

=item $handler->eprint( $r )

A request on an eprint abstract page.

=cut
######################################################################

sub eprint
{
	my( $r ) = @_;

	# e.g. ignore 304 NOT MODIFIED
	if( $r->status != 200 )
	{
		return DECLINED;
	}

	# only track hits on the full abstract page
	if( $r->filename !~ /\bindex\.html$/ )
	{
		return DECLINED;
	}
	
	my $eprint = $r->pnotes( "eprint" );

	my $ip = $eprint->repository->remote_ip;
	return if is_robot( $r, $ip );

	my $epdata = _generic( $r, { _parent => $eprint } );

	$epdata->{requester_id} = $ip;
	$epdata->{service_type_id} = "?abstract=yes";
	$epdata->{referent_id} = $eprint->id;

	return _create_access( $r, $epdata );
}

sub _generic
{
	my( $r, $epdata ) = @_;

	$epdata->{datestamp} = EPrints::Time::get_iso_timestamp( $r->request_time );
	$epdata->{referring_entity_id} = $r->headers_in->{ "Referer" };
	$epdata->{requester_user_agent} = $r->headers_in->{ "User-Agent" };

	# Sanity check referring URL (don't store non-HTTP referrals)
	if( !$epdata->{referring_entity_id} || $epdata->{referring_entity_id} !~ /^https?:/ )
	{
		$epdata->{referring_entity_id} = '';
	}

	return $epdata;
}

sub _create_access
{
	my( $r, $epdata ) = @_;

	my $repository = $EPrints::HANDLE->current_repository;
	if( !defined $repository )
	{
		return DECLINED;
	}

	my $access_table_logger_disabled = $repository->config( "access_table_logger_disabled" );

	unless( defined( $access_table_logger_disabled ) && $access_table_logger_disabled )
        {
                $repository->dataset( "access" )->create_dataobj( $epdata );
        }

        my $access_logger_func = $repository->config( "access_logger_func" );

        if( defined( $access_logger_func ) )
        {
                eval { &{$access_logger_func}( $repository, $epdata ); };
        }

	return OK;
}

1;

__END__

=back

=head1 SEE ALSO

L<EPrints::DataObj::Access>


=head1 COPYRIGHT

=for COPYRIGHT BEGIN

Copyright 2022 University of Southampton.
EPrints 3.4 is supplied by EPrints Services.

http://www.eprints.org/eprints-3.4/

=for COPYRIGHT END

=for LICENSE BEGIN

This file is part of EPrints 3.4 L<http://www.eprints.org/>.

EPrints 3.4 and this file are released under the terms of the
GNU Lesser General Public License version 3 as published by
the Free Software Foundation unless otherwise stated.

EPrints 3.4 is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See the GNU Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with EPrints 3.4.
If not, see L<http://www.gnu.org/licenses/>.

=for LICENSE END

