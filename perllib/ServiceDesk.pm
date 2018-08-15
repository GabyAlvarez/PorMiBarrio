package ServiceDesk;

use URI;
use Moose;
use XML::Simple;
use LWP::Simple;
use LWP::UserAgent;
use DateTime::Format::W3CDTF;
use HTTP::Request::Common qw(POST);
use warnings;
use Data::Dumper;
use Path::Class;

has jurisdiction => ( is => 'ro', isa => 'Str' );;
has api_key => ( is => 'ro', isa => 'Str' );
has endpoint => ( is => 'ro', isa => 'Str' );
has test_mode => ( is => 'ro', isa => 'Bool' );
has test_uri_used => ( is => 'rw', 'isa' => 'Str' );
has test_req_used => ( is => 'rw' );
has test_get_returns => ( is => 'rw' );
has endpoints => ( is => 'rw', default => sub { { services => 'admin/item/subcategory/', requests => 'request', service_request_updates => 'servicerequestupdates.xml', update => 'servicerequestupdates.xml', service_request_new => 'newServiceRequestLogs.xml', groups => 'admin/subcategory/category/' } } );
has debug => ( is => 'ro', isa => 'Bool', default => 0 );
has debug_details => ( is => 'rw', 'isa' => 'Str', default => '' );
has success => ( is => 'rw', 'isa' => 'Bool', default => 0 );
has error => ( is => 'rw', 'isa' => 'Str', default => '' );
has always_send_latlong => ( is => 'ro', isa => 'Bool', default => 1 );
has send_notpinpointed => ( is => 'ro', isa => 'Bool', default => 0 );
has extended_description => ( is => 'ro', isa => 'Str', default => 1 );
has use_service_as_deviceid => ( is => 'ro', isa => 'Bool', default => 0 );
has use_extended_updates => ( is => 'ro', isa => 'Bool', default => 0 );
has extended_statuses => ( is => 'ro', isa => 'Bool', default => 0 );
has main_category => ( is => 'ro', isa => 'Str', default => '301' );

before [
    qw/get_service_list get_service_meta_info get_service_requests get_service_request_updates
      send_service_request post_service_request_update/
  ] => sub {
    shift->debug_details('');
  };

sub get_service_list {
  my $self = shift;
  my $group_id = shift;

  my $params = {
    OPERATION_NAME => 'GET_ALL',
    TECHNICIAN_KEY => mySociety::Config::get('USER_KEY_SD', undef),
  };
  my $service_list_xml = $self->_post( $self->endpoints->{services}.$group_id, $params );
  if ( $service_list_xml ) {
    my $response = $self->_get_xml_object( $service_list_xml );
    return $response->{ response }->{ operation }->{Details}->{record};
  } else {
    return undef;
  }
}
sub get_group_list {
  my $self = shift;
  my $group_id = shift;

  my $params = {
    OPERATION_NAME => 'GET_ALL',
    TECHNICIAN_KEY => mySociety::Config::get('USER_KEY_SD', undef),
  };
  my $service_list_xml = $self->_post( $self->endpoints->{groups}.$self->main_category, $params );
  if ( $service_list_xml ) {
    my $response = $self->_get_xml_object( $service_list_xml );
    return $response->{ response }->{ operation }->{Details}->{record};
  }
  else {
    return undef;
  }
}
sub get_service_meta_info {
    my $self = shift;
    my $service_id = shift;

    my $service_meta_xml = $self->_get( "services/$service_id.xml" );
    return $self->_get_xml_object( $service_meta_xml );
}

sub get_service_custom_meta_info {
    my $self = shift;
    my $service_id = shift;

    my $service_meta_xml = $self->_get( "requests/$service_id.xml" );
    return $self->_get_xml_object( $service_meta_xml );
}

#Servicio para obtener los Ids de problemas nuevos
sub get_service_problems {
    my $self = shift;
    my $start_date = shift;
    my $end_date = shift;

    my $params = {};

    if ( $start_date || $end_date ) {
        return 0 unless $start_date && $end_date;

        $params->{start_date} = $start_date;
        $params->{end_date} = $end_date;
    }
    my $xml = $self->_get( $self->endpoints->{service_request_new}, $params || undef );
    my $service_requests = $self->_get_xml_object( $xml );
    my $requests;
    if ( ref $service_requests->{request} eq 'ARRAY' ) {
        $requests = $service_requests->{request};
    }
    else {
        $requests = [ $service_requests->{request} ];
    }

    return $requests;
}

sub send_service_request {
    my $self = shift;
    my $problem = shift;
    my $extra = shift;
    my $service_code = shift;

    my $params = $self->_populate_service_request_params(
        $problem, $extra, $service_code
    );

    my $response = $self->_post( $self->endpoints->{requests}, $params );

    if ( $response ) {
        my $obj = $self->_get_xml_object( $response );
        if ( $obj ) {
            if ( $obj->{ response }->{ operation }->{Details}->[0]->{workorderid} ) {
                my $request_id = $obj->{ response }->{ operation }->{Details}->[0]->{workorderid};
                if ( $problem->photo ) {
                    #CALL ATTACH
                    $self->_send_attachment($problem->photo, $request_id);
                }
                unless ( ref $request_id ) {
                    return $request_id;
                }
            } else {
                my $token = $obj->{ request }->{ token };
                if ( $token ) {
                    return $self->get_service_request_id_from_token( $token );
                }
            }
        }

        warn sprintf( "Failed to submit problem %s over ServiceDesk, response\n: %s\n%s", $problem->id, $response, $self->debug_details )
            unless $problem->send_fail_count;
    } else {
        warn sprintf( "Failed to submit problem %s over ServiceDesk, details:\n%s", $problem->id, $self->error)
            unless $problem->send_fail_count;
    }
    return 0;
}

sub _populate_service_request_params {
    my $self = shift;
    my $problem = shift;
    my $extra = shift;
    my $service_code = shift;

    my $description;
    if ( $self->extended_description ) {
        $description = $self->_generate_service_request_description(
            $problem, $extra
        );
    } else {
        $description = $problem->detail;
    }

    my ( $firstname, $lastname ) = ( $problem->name =~ /(\w+)\.?\s+(.+)/ );

    my $params = {
      requester => mySociety::Config::get('USER_AUTH_SD', undef),
      subject => $problem->title,
      description => substr($description, 0, 1950),
      service_code => $service_code,
    };
    $params->{user} = {
      email => $problem->user->email,
      first_name => $firstname,
      last_name => $lastname || '',
    };

    # if you click nearby reports > skip map then it's possible
    # to end up with used_map = f and nothing in postcode
    if ( $problem->used_map || $self->always_send_latlong || ( !$self->send_notpinpointed && !$problem->used_map && !$problem->postcode ) ) {
        $params->{site} = $problem->latitude;#.', '.$problem->longitude;
    # this is a special case for sending to Bromley so they can
    # report accuracy levels correctly. We include easting and
    # northing as attributes elsewhere.
    } elsif ( $self->send_notpinpointed && !$problem->used_map
              && !$problem->postcode ) {
        $params->{site} = '#NOTPINPOINTED#';
    } else {
        $params->{site} = $problem->postcode;
    }
    #Agregado PMB
    if ( $problem->{address_string} ){
        $params->{site} = $problem->{address_string};
    }
    if ( $problem->user->identity_document ) {
        $params->{user}->{ document } = $problem->user->identity_document;
    }
    if ( $problem->user->phone ) {
        $params->{user}->{ phone } = $problem->user->phone;
    }
    if ( $self->use_service_as_deviceid && $problem->service ) {
        $params->{deviceid} = $problem->service;
    }

    if ( $problem->extra ) {
        my $extras = $problem->extra;

        for my $attr ( @$extras ) {
            my $attr_name = $attr->{name};
            if ( $attr_name eq 'first_name' || $attr_name eq 'last_name' ) {
                $params->{$attr_name} = $attr->{value} if $attr->{value};
                next if $attr_name eq 'first_name';
            }
            $attr_name =~ s/fms_extra_//;
            my $name = sprintf( 'attribute[%s]', $attr_name );
            $params->{ $name } = $attr->{value};
        }
    }
    #TODO define structure acording to the SD structure
    $params->{ service } = 'Infraestructure fixes';
    $params->{ request_type } = 'Infrastructure report';
    $params->{ priority } = 'High';
    $params->{ mode } = 'PMB';
    $params->{ category } = 'PMB Test';
    $params->{ subcategory } = 'Problemas en arroyos';
    $params->{ item } = 'Item del problema';

    my $xs = XML::Simple->new(ForceArray => 1, KeepRoot => 1, NoAttr => 1);
    my $xml_params = $xs->XMLout( { Operation => { Details => $params } } );

    return {
      OPERATION_NAME => 'ADD_REQUEST',
      TECHNICIAN_KEY => mySociety::Config::get('USER_KEY_SD', undef),
      INPUT_DATA => $xml_params
    };
}

sub _send_attachment {
  my $self = shift;
  my $photo = shift;
  my $request_id = shift;
  print "\n ENTRA A ATTACH: \n";
  my $uri = URI->new( $self->endpoint );
  $uri->path( $uri->path . $self->endpoints->{requests}.'/'.$request_id.'/attachment' );

  my $req = POST $uri->as_string."?OPERATION_NAME=ADD_ATTACHMENT&TECHNICIAN_KEY=".mySociety::Config::get('USER_KEY_SD', undef),
  Content_Type => 'multipart/form-data',
  Content => [ filename => [FixMyStreet->path_to( 'web/upload' )->stringify."/$photo.jpeg"] ];

  my $ua = LWP::UserAgent->new;
  $ua->ssl_opts(verify_hostname => 0);
  my $res;

  if ( $self->test_mode ) {
      $res = $self->test_get_returns->{ $req };
      $self->test_req_used( $req );
  } else {
      $res = $ua->request( $req );
  }
  print Dumper($res);
  if ( $res->is_success ) {
    print "SUCCESS";
    return 1;
  }
  else {
    return 0;
  }
}

sub _generate_service_request_description {
    my $self = shift;
    my $problem = shift;
    my $extra = shift;

    my $description = <<EOT;
detalles: @{[$problem->detail()]}

url: $extra->{url}

Enviado por PorMiBarrio
EOT
;
    if ($self->extended_description ne 'oxfordshire') {
        $description = <<EOT . $description;
titulo: @{[$problem->title()]}

EOT
    }

    return $description;
}

sub get_service_requests {
    my $self = shift;
    my $report_ids = shift;

    my $params = {};

    if ( $report_ids ) {
        $params->{service_request_id} = join ',', @$report_ids;
    }

    my $service_request_xml = $self->_get( $self->endpoints->{requests}, $params || undef );
    return $self->_get_xml_object( $service_request_xml );
}

sub get_service_request_id_from_token {
    my $self = shift;
    my $token = shift;

    my $service_token_xml = $self->_get( "tokens/$token.xml" );

    my $obj = $self->_get_xml_object( $service_token_xml );

    if ( $obj && $obj->{ request }->{ service_request_id } ) {
        return $obj->{ request }->{ service_request_id };
    } else {
        return 0;
    }
}

sub get_service_request_updates {
    my $self = shift;
    my $start_date = shift;
    my $end_date = shift;

    my $params = {
        #api_key => $self->api_key,
        #jurisdiction => $self->jurisdiction,
    };

    if ( $start_date || $end_date ) {
        return 0 unless $start_date && $end_date;

        $params->{start_date} = $start_date;
        $params->{end_date} = $end_date;
    }

    my $xml = $self->_get( $self->endpoints->{service_request_updates}, $params || undef );
    my $service_requests = $self->_get_xml_object( $xml );
    my $requests;
    if ( ref $service_requests->{request_update } eq 'ARRAY' ) {
        $requests = $service_requests->{request_update};
    }
    else {
        $requests = [ $service_requests->{request_update} ];
    }

    return $requests;
}

sub post_service_request_update {
    my $self = shift;
    my $comment = shift;

    my $params = $self->_populate_service_request_update_params( $comment );

    my $response = $self->_post( $self->endpoints->{update}, $params );

    if ( $response ) {
        my $obj = $self->_get_xml_object( $response );

        if ( $obj ) {
            if ( $obj->{ request_update }->{ update_id } ) {
                my $update_id = $obj->{request_update}->{update_id};

                # if there's nothing in the update_id element we get a HASHREF back
                unless ( ref $update_id ) {
                    return $obj->{ request_update }->{ update_id };
                }
            } else {
                my $token = $obj->{ request_update }->{ token };
                if ( $token ) {
                    return $self->get_service_request_id_from_token( $token );
                }
            }
        }

        warn sprintf( "Failed to submit comment %s over ServiceDesk, response - %s\n%s\n", $comment->id, $response, $self->debug_details )
            unless $comment->send_fail_count;
    } else {
        warn sprintf( "Failed to submit comment %s over ServiceDesk, details\n%s\n", $comment->id, $self->error)
            unless $comment->send_fail_count;
    }
    return 0;
}

sub _populate_service_request_update_params {
    my $self = shift;
    my $comment = shift;

    my $name = $comment->name || $comment->user->name;
    my ( $firstname, $lastname ) = ( $name =~ /(\w+)\.?\s+(.+)/ );
    $lastname ||= '-';

    # fall back to problem state as it's probably correct
    my $state = $comment->problem_state || $comment->problem->state;

    my $status = 'OPEN';
    if ( $self->extended_statuses ) {
        if ( FixMyStreet::DB::Result::Problem->fixed_states()->{$state} ) {
            $status = 'FIXED';
        } elsif ( $state eq 'in progress' ) {
            $status = 'IN_PROGRESS';
        } elsif ($state eq 'action scheduled'
            || $state eq 'planned' ) {
            $status = 'ACTION_SCHEDULED';
        } elsif ( $state eq 'investigating' ) {
            $status = 'INVESTIGATING';
        } elsif ( $state eq 'duplicate' ) {
            $status = 'DUPLICATE';
        } elsif ( $state eq 'not responsible' ) {
            $status = 'NOT_COUNCILS_RESPONSIBILITY';
        } elsif ( $state eq 'unable to fix' ) {
            $status = 'NO_FURTHER_ACTION';
        } elsif ( $state eq 'internal referral' ) {
            $status = 'INTERNAL_REFERRAL';
        }
    } else {
        if ( !FixMyStreet::DB::Result::Problem->open_states()->{$state} ) {
            $status = 'CLOSED';
        }
    }

    my $params = {
        updated_datetime => DateTime::Format::W3CDTF->format_datetime($comment->confirmed->set_nanosecond(0)),
        service_request_id => $comment->problem->external_id,
        status => $status,
        email => $comment->user->email,
        description => $comment->text,
        last_name => $lastname,
        first_name => $firstname,
    };

    if ( $self->use_extended_updates ) {
        $params->{public_anonymity_required} = $comment->anonymous ? 'TRUE' : 'FALSE',
        $params->{update_id_ext} = $comment->id;
        $params->{service_request_id_ext} = $comment->problem->id;
    } else {
        $params->{update_id} = $comment->id;
    }

    if ( $comment->photo ) {
        my $cobrand = FixMyStreet::Cobrand->get_class_for_moniker($comment->cobrand)->new();
        my $email_base_url = $cobrand->base_url($comment->cobrand_data);
        my $url = $email_base_url . '/photo/c/' . $comment->id . '.full.jpeg';
        $params->{media_url} = $url;
    }

    if ( $comment->extra ) {
        $params->{'email_alerts_requested'}
            = $comment->extra->{email_alerts_requested} ? 'TRUE' : 'FALSE';
        $params->{'title'} = $comment->extra->{title};

        $params->{first_name} = $comment->extra->{first_name} if $comment->extra->{first_name};
        $params->{last_name} = $comment->extra->{last_name} if $comment->extra->{last_name};
    }

    return $params;
}

sub _get {
    my $self   = shift;
    my $path   = shift;
    my $params = shift || {};

    my $uri = URI->new( $self->endpoint );

    #$params->{ jurisdiction_id } = $self->jurisdiction;
    $uri->path( $uri->path . $path );
    $uri->query_form( $params );

    $self->debug_details( $self->debug_details . "\nrequest:" . $uri->as_string );
    print "GET";
    my $content;
    if ( $self->test_mode ) {
        $self->success(1);
        $content = $self->test_get_returns->{ $path };
        $self->test_uri_used( $uri->as_string );
    } else {
        my $ua = LWP::UserAgent->new;
        my $user = mySociety::Config::get('HTTPS_USER_AUTH', undef);
        my $password = mySociety::Config::get('HTTPS_PASS_AUTH', undef);
        $ua->ssl_opts(verify_hostname => 0);
        $ua->credentials("www.montevideo.gub.uy:443", "www.montevideo.gub.uy:443", $user, $password);

        my $req = HTTP::Request->new(
            GET => $uri->as_string
        );

        print 'URI: '.$uri->as_string;
        my $res = $ua->request( $req );

        if ( $res->is_success ) {
            $content = $res->decoded_content;
            $self->success(1);
        } else {
            $self->success(0);
            $self->error( sprintf(
                "request failed: %s\n%s\n",
                $res->status_line,
                $uri->as_string
            ) );
        }
    }

    return $content;
}

sub _post {
    my $self = shift;
    my $path   = shift;
    my $params = shift;
    my $content_type = shift || "application/x-www-form-urlencoded;charset=utf-8";

    my $uri = URI->new( $self->endpoint );
    $uri->path( $uri->path . $path );

    my $req = POST $uri->as_string,
    [
        #jurisdiction_id => $self->jurisdiction,
        #api_key => $self->api_key,
        %{ $params }
    ], Content_Type => $content_type;

    $self->debug_details( $self->debug_details . "\nrequest:" . $req->as_string );

    my $ua = LWP::UserAgent->new;
    $ua->ssl_opts(verify_hostname => 0);
    my $res;

    if ( $self->test_mode ) {
        $res = $self->test_get_returns->{ $path };
        $self->test_req_used( $req );
    } else {
        $res = $ua->request( $req );
    }
    print "\n\nRESULT\n";
    print Dumper($res);
    if ( $res->is_success ) {
        print "SUCCESS";
        $self->success(1);
        return $res->decoded_content;
    } else {
        if ( $res->{_rc} eq 302 ){
            print "\n\nREDIRECTION:\n";
            my $res_headers = $res->{_headers};
            my $h = HTTP::Headers->new(
                'content-length' => $req->{_headers}->{"content-length"},
                Content_Type => "application/x-www-form-urlencoded;charset=utf-8"
            );
            $req = HTTP::Request->new('POST', $res_headers->{location}, $h, $req->{_content} );
            $res = $ua->request( $req );
            if ( $res->is_success ) {
                print "SUCCESS";
                $self->success(1);
                return $res->decoded_content;
            }
        }
        $self->success(0);
        print "ERROR";
        print Dumper($res);
        $self->error( sprintf(
            "request failed: %s\nerror: %s\n%s\n",
            $res->status_line,
            $self->_process_error( $res->decoded_content ),
            $self->debug_details
        ) );
        return 0;
    }
}

sub _process_error {
    my $self = shift;
    my $error = shift;

    my $obj = $self->_get_xml_object( $error );

    my $msg = '';
    if ( ref $obj && exists $obj->{error} ) {
        my $errors = $obj->{error};
        $errors = [ $errors ] if ref $errors ne 'ARRAY';
        $msg .= sprintf( "%s: %s\n", $_->{rc}, $_->{_msg} ) for @{ $errors };
    }

    return $msg || 'unknown error';
}

sub _get_xml_object {
    my $self = shift;
    my $xml= shift;

    my $simple = XML::Simple->new();
    my $obj;

    eval {
        $obj = $simple ->parse_string( $xml, ForceArray => [ qr/^key$/ ]  );
    };

    return $obj;
}
1;
