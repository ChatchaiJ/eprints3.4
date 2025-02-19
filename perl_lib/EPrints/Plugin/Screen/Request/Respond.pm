=head1 NAME

EPrints::Plugin::Screen::Request::Respond

=cut


package EPrints::Plugin::Screen::Request::Respond;

use EPrints::Plugin::Screen;

@ISA = ( 'EPrints::Plugin::Screen' );

use strict;

sub new
{
	my( $class, %params ) = @_;

	my $self = $class->SUPER::new(%params);

	$self->{actions} = [qw/ confirm /];

	return $self;
}

sub properties_from
{
	my( $self ) = @_;

	# Need valid requestid
	$self->{processor}->{requestid} = $self->{session}->param( "requestid" );
	$self->{processor}->{request} = new EPrints::DataObj::Request( $self->{session}, $self->{processor}->{requestid} );
	if( !defined $self->{processor}->{request} )
	{
		&_properties_error;
		return;
	}

	$self->{processor}->{document} = EPrints::DataObj::Document->new(
				$self->{session}, $self->{processor}->{request}->get_value( "docid" ) );

	$self->{processor}->{eprint} = EPrints::DataObj::EPrint->new(
				$self->{session}, $self->{processor}->{request}->get_value( "eprintid" ) );

	$self->{processor}->{contact} = EPrints::DataObj::User->new(
				$self->{session}, $self->{processor}->{request}->get_value( "userid" ) );

	# Need valid document, eprint and contact
	if( !defined $self->{processor}->{document} ||
		!defined $self->{processor}->{eprint} ||
		!defined $self->{processor}->{contact} )
	{
		&_properties_error;
		return;
	}

	$self->{processor}->{response_sent} = $self->{session}->param( "response_sent" );
	$self->{processor}->{actionid} = $self->{session}->param( "action" );

	$self->SUPER::properties_from;

}

sub _properties_error
{
	my( $self ) = @_;
	
	$self->{processor}->{screenid} = "Error";
	$self->{processor}->add_message( "error", $self->{session}->html_phrase( "general:bad_param" ) );
}

sub can_be_viewed
{
	my( $self ) = @_;

	# Only the contact user (ie. user listed as contact email at time of request) can process it
	return $self->{processor}->{contact}->get_id == $self->{processor}->{user}->get_id;
}

sub allow_confirm
{
	return 1;
}

sub action_confirm
{
	my( $self ) = @_;

	my $session = $self->{session};

	my $eprint = $self->{processor}->{eprint};
	my $doc = $self->{processor}->{document};

	my $email = $self->{processor}->{request}->get_value( "requester_email" );
	unless( EPrints::Utils::validate_email( $email ) )
	{
		$self->{processor}->add_message( "error", $self->{session}->html_phrase(
			"general:bad_email", email => $session->make_text( $email ) ) );
		return;		
	}

	my $action = $session->param("action");
	$action = "reject" if !defined $action || $action ne "accept";
	# Requested document has been made OA in the meantime
	$action = "oa" if $self->{processor}->{document}->is_public;

	my $subject = $session->phrase( 
		"request/response_email:subject", 
		eprint => $eprint->get_value( "title" ) );

	my $mail = $session->make_element( "mail" );
	my $reason = $session->param( "reason" );
	$mail->appendChild( $session->html_phrase(
		"request/response_email:body_$action",
		eprint => $eprint->render_citation_link,
		document => $doc->render_value( "main" ),
		reason => EPrints::Utils::is_set( $reason ) ? $session->make_text( $reason )
			: $session->html_phrase( "Plugin/Screen/EPrint/RequestRemoval:reason" ) ) );

	my $result;
	if( $action eq "accept")
	{
	
		# Make document OA if flag set
		if( defined $session->param( "oa" ) && $session->param( "oa" ) eq "on" )
		{
			$doc->set_value( "security", "public" );
			$doc->commit;
			$eprint->commit;
			$eprint->generate_static;
		}

		my $expiry = $session->config( "expiry_for_doc_request" );
		$expiry = 7 if( !defined $expiry || $expiry !~ /^\d+$/ );
		$expiry = time + $expiry*3600*24;

		$self->{processor}->{request}->set_value(
				       "expiry_date" ,
				       EPrints::Time::get_iso_timestamp( $expiry )
		);

		my $code = $self->{processor}->{request}->get_value( "code" );
		if ( !EPrints::Utils::is_set( $code ) )
		{
			my @a = ();
			srand;
			for(1..16) { push @a, sprintf( "%02X",int rand 256 ); }
			$code = join( "", @a );
			$self->{processor}->{request}->set_value( "code", "$code" );
			$self->{processor}->{request}->commit;
		}
		# Make HTTPS if available to allow SameSite for cookie to be set to None to avoid authentication popups when getting restricted document.	
		my $cgi_url = $session->config( "perl_url" )."/process_request?code=$code";
		my $link = $session->make_element( "a", href=>"$cgi_url" );
		$link->appendChild( $session->html_phrase( "request/response_email:download_label" ) );
		$mail->appendChild( $link );

		$mail->appendChild( $session->html_phrase( "request/response_email:warning_expiry",
					       expiry => $session->make_text( EPrints::Time::human_time( $expiry )  ) ) );


		$result = EPrints::Email::send_mail(
			session => $session,
			langid => $session->get_langid,
			to_email => $email,
			subject => $subject,
			message => $mail,
			sig => $session->html_phrase( "mail_sig" ),
		);
	}
	else
	{
		# Send rejection notice
		$result = EPrints::Email::send_mail(
			session => $session,
			langid => $session->get_langid,
			to_email => $email,
			subject => $subject,
			message => $mail,
			sig => $session->html_phrase( "mail_sig" ),
		);
	}
	
	# Log response event
	my $history_ds = $session->dataset( "history" );
	my $user = $self->{processor}->{contact};
	$history_ds->create_object(
		$session,
		{
			userid =>$user->get_id,
			actor=>EPrints::Utils::tree_to_utf8( $user->render_description ),
			datasetid=>"request",
			objectid=>$self->{processor}->{request}->get_id,
			action=> "$action\_request",
			details=>EPrints::Utils::is_set( $reason ) ? $reason : undef,
		}
	);

	if( !$result )
	{
		$self->{processor}->add_message( "error", $self->{session}->html_phrase(
			"general:email_failed" ) );
		return;
	}

	$self->{processor}->add_message( "message", $self->{session}->html_phrase( "request/response:ack_page" ) );
	$self->{processor}->{response_sent} = 1;
}

sub redirect_to_me_url
{
	my( $self ) = @_;

	my $url = $self->SUPER::redirect_to_me_url;
	if( defined $self->{processor}->{requestid} )
	{
		$url.="&requestid=".$self->{processor}->{requestid};
	}
	if( defined $self->{processor}->{actionid} )
	{
		$url.="&action=".$self->{processor}->{actionid};
	}
	if( defined $self->{processor}->{response_sent} )
	{
		$url.="&response_sent=".$self->{processor}->{response_sent};
	}
	return $url;
}

sub render
{
	my( $self ) = @_;

	my $session = $self->{session};

	my $page = $session->make_doc_fragment();
	return $page if $self->{processor}->{response_sent};

	my $email = $self->{processor}->{request}->get_value( "email" );

	my $action = $session->param("action");
	$action = "reject" if !defined $action || $action ne "accept";
	# Requested document has been made OA in the meantime
	$action = "oa" if $self->{processor}->{document}->is_public;

	if ( EPrints::Utils::is_set( $self->{processor}->{request}->get_value( "code" ) ) )
	{
		$page->appendChild( $session->html_phrase( "request/respond_page:already_approved" ) );
	}

	$page->appendChild( $session->html_phrase(
		"request/respond_page:$action",
		eprint => $self->{processor}->{eprint}->render_citation_link,
		document => $self->render_document,
	) );

	my $form =  $session->render_form( "post" );
	$page->appendChild( $form );
	
	if( $action eq "reject" )
	{
		my $textarea = $session->make_element( "textarea", 
			name => "reason",
			rows => 5,
			cols => 60,
			wrap => "virtual",
		);
		$form->appendChild( $textarea );
	}

	# Only display the 'Make this document OA' form if the user
	# has privilege to edit this document
	if( $action eq "accept"
		 && $self->allow( 'eprint/archive/edit', $self->{processor}->{eprint} ) )
	{
		my $p = $session->make_element( "p" );
		$form->appendChild( $p );
		my $label = $session->make_element( "label" );
		my $cb = $session->make_element( "input", type => "checkbox", name => "oa" );
		$label->appendChild( $cb );
		$label->appendChild( $session->make_text( " " ));
		$label->appendChild( $session->html_phrase(
			"request/respond_page:fieldname_oa" ) );
		$p->appendChild( $label );
	}

	$form->appendChild( $session->render_hidden_field( "screen", $self->{processor}->{screenid} ) );
	$form->appendChild( $session->render_hidden_field( "requestid", $self->{processor}->{request}->get_id ) );
	$form->appendChild( $session->render_hidden_field( "action", $action ) );

	$form->appendChild( $session->make_element( "br" ) );
	$form->appendChild( $session->render_action_buttons( confirm => $session->phrase( "request/respond_page:action_respond" ) ) );

	return $page;

}

sub render_document
{
	my( $self ) = @_;

	my $session = $self->{session};
	my $doc = $self->{processor}->{document};

	my( $doctable, $doctr, $doctd );
	$doctable = $session->make_element( "table" );
	$doctr = $session->make_element( "tr" );
	
	$doctd = $session->make_element( "td" );
	$doctr->appendChild( $doctd );
	$doctd->appendChild( $doc->render_icon_link );
	
	$doctd = $session->make_element( "td" );
	$doctr->appendChild( $doctd );
	$doctd->appendChild( $doc->render_citation_link() );
	my %files = $doc->files;
	if( defined $files{$doc->get_main} )
	{
		my $size = $files{$doc->get_main};
		$doctd->appendChild( $session->make_element( 'br' ) );
		$doctd->appendChild( $session->make_text( EPrints::Utils::human_filesize($size) ));
	}

	$doctable->appendChild( $doctr );

	return $doctable;
}

1;

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

