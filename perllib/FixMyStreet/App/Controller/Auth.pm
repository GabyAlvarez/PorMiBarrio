package FixMyStreet::App::Controller::Auth;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

use Email::Valid;
use Net::Domain::TLD;
use mySociety::AuthToken;
use JSON;
use Net::Facebook::Oauth2;
use Net::Twitter::Lite::WithAPIv1_1;
use Digest::HMAC_SHA1;

=head1 NAME

FixMyStreet::App::Controller::Auth - Catalyst Controller

=head1 DESCRIPTION

Controller for all the authentication related pages - create account, sign in,
sign out.

=head1 METHODS

=head2 index

Present the user with a sign in / create account page.

=cut

sub general : Path : Args(0) {
    my ( $self, $c ) = @_;
    my $req = $c->req;

    $c->detach( 'redirect_on_signin', [ $req->param('r') ] )
        if $c->user && $req->param('r');

    # all done unless we have a form posted to us
    return unless $req->method eq 'POST';

    # decide which action to take
    $c->detach('facebook_login') if $req->param('facebook_login');
    $c->detach('twitter_login') if $req->param('twitter_login');

    $c->detach('email_sign_in') if $req->param('email_sign_in')
        || $c->req->param('name') || $c->req->param('password_register');

       $c->forward( 'sign_in' )
    && $c->detach( 'redirect_on_signin', [ $req->param('r') ] );

}

=head2 sign_in

Allow the user to sign in with a username and a password.

=cut

sub sign_in : Private {
    my ( $self, $c, $email ) = @_;

    $email        ||= $c->req->param('email')            || '';
    my $password    = $c->req->param('password_sign_in') || '';
    my $remember_me = $c->req->param('remember_me')      || 0;

    # Sign out just in case
    $c->logout();

    if (   $email
        && $password
        && $c->authenticate( { email => $email, password => $password } ) )
    {

        # unless user asked to be remembered limit the session to browser
        $c->set_session_cookie_expire(0)
          unless $remember_me;

        return 1;
    }

    $c->stash(
        sign_in_error => 1,
        email => $email,
        remember_me => $remember_me,
    );
    return;
}

=head2 email_sign_in

Email the user the details they need to sign in. Don't check for an account - if
there isn't one we can create it when they come back with a token (which
contains the email addresss).

=cut

sub email_sign_in : Private {
    my ( $self, $c ) = @_;

    # check that the email is valid - otherwise flag an error
    my $raw_email = lc( $c->req->param('email') || '' );

    my $email_checker = Email::Valid->new(
        -mxcheck  => 1,
        -tldcheck => 1,
        -fqdn     => 1,
    );

    my $good_email = $email_checker->address($raw_email);
    if ( !$good_email ) {
        $c->stash->{email} = $raw_email;
        $c->stash->{email_error} =
          $raw_email ? $email_checker->details : 'missing';
        return;
    }

    my $user_params = {};
    $user_params->{password} = $c->req->param('password_register')
        if $c->req->param('password_register');
    my $user = $c->model('DB::User')->new( $user_params );

    my $token_obj = $c->model('DB::Token')    #
      ->create(
        {
            scope => 'email_sign_in',
            data  => {
                email => $good_email,
                r => $c->req->param('r'),
                name => $c->req->param('name'),
                password => $user->password,
            }
        }
      );

    $c->stash->{token} = $token_obj->token;
    $c->send_email( 'login.txt', { to => $good_email } );
    $c->stash->{template} = 'auth/token.html';
}

=head2 facebook_login

Starts the Facebook authentication sequence.

=cut

sub facebook_login : Private {
	my( $self, $c ) = @_;
	
	my $params = $c->req->parameters;
    
    # TODO: move Facebook App ID/Secret to general.yaml!
	my $fb = Net::Facebook::Oauth2->new(
		application_id => '1479349985610467',  ##get this from your facebook developers platform
		application_secret => '6abe6b58ff5d090080d6ab989a8b41de', ##get this from your facebook developers platform
		callback => 'http://ituland.no-ip.org:9000/auth/Facebook',  ##Callback URL, facebook will redirect users after authintication
	);
	
	##there is no verifier code passed so let's create authorization URL and redirect to it
	
	my $url = $fb->get_authorization_url(
		scope => ['email'], ###pass scope/Extended Permissions params as an array telling facebook how you want to use this access
		display => 'page' ## how to display authorization page, other options popup "to display as popup window" and wab "for mobile apps"
	);
	
	###save this token in session
	my $return_url = $c->stash->{return_url} or $c->req->param('r');
	#$c->log->debug('========== facebook_login token_url: '.$return_url);
	
	$c->session->{oauth} =  {
		r => $return_url
	};
	
	$c->res->redirect($url);
}

=head2 facebook_callback

Handles the Facebook callback request and completes the authentication sequence.

=cut

sub facebook_callback: Path('/auth/Facebook') : Args(0) {
	my( $self, $c ) = @_;
	
	my $params = $c->req->parameters;

	# TODO: move Facebook App ID/Secret to general.yaml!
	my $fb = Net::Facebook::Oauth2->new(
		application_id => '1479349985610467',  ##get this from your facebook developers platform
		application_secret => '6abe6b58ff5d090080d6ab989a8b41de', ##get this from your facebook developers platform
		callback => 'http://ituland.no-ip.org:9000/auth/Facebook',  ##Callback URL, facebook will redirect users after authintication
	);
	
	###you need to pass the verifier code to get access_token	
	my $access_token = $fb->get_access_token( code => $params->{code} );
	
	###save this token in session
	$c->session->{oauth} =  {
		token => $access_token,
		r => $c->session->{oauth}{r}
	};
	
	my $info = $fb->get('https://graph.facebook.com/me')->as_hash();
		
	my $name = $info->{'name'};
	my $email = $info->{'email'};
	my $uid = $info->{'id'};

	$c->log->debug("============= Name: $name");
	$c->log->debug("============= Email: $email");
	$c->log->debug("============= UID: $uid");

	my $user_pmb = $c->model('DB::UsersPmb')->find( { facebook_id => $uid } );
	
	if (!$user_pmb) {
		$c->session->{social_info} = {
			email => $email,
			name => $name,
			facebook_id => $uid,
			twitter_id => undef
		};

		$c->res->redirect( $c->uri_for( '/auth/social_signup' ) );
	} else {	
		$c->session->{user_pmb} = {
			id => $user_pmb->id->id,
			ci => $user_pmb->ci,
			facebook_id => $user_pmb->facebook_id,
			twitter_id => $user_pmb->twitter_id
		};
		
		$c->authenticate( { email => $user_pmb->id->email }, 'no_password' );

		# send the user to their page
		$c->detach( 'redirect_on_signin', [ $c->session->{oauth}{r} ] );
	}
}

=head2 twitter_login

Starts the Twitter authentication sequence.

=cut

sub twitter_login : Private {
	my( $self, $c ) = @_;
	
	# TODO: move Tweeter App ID/Secret to general.yaml!
	my %consumer_tokens = (
		consumer_key    => 'ywz9X5JbAvN3zQDn10TQvzoJm',
		consumer_secret => 'XP9cLG53fJsR2dGecvh9E4X5xFjqhYmOZRoFy1OJQJZGVYTy9i',
	);
	
	my $twitter = Net::Twitter::Lite::WithAPIv1_1->new(ssl => 1, %consumer_tokens);
    my $url = $twitter->get_authorization_url(callback => 'http://ituland.no-ip.org:9000/auth/Twitter');

	my $return_url = $c->stash->{return_url} or $c->req->param('r');

	$c->session->{oauth} = {
		token => $twitter->request_token,
		token_secret => $twitter->request_token_secret,
		r => $return_url
	};

	$c->res->redirect($url);
}

=head2 twitter_callback

Handles the Twitter callback request and completes the authentication sequence.

=cut

sub twitter_callback: Path('/auth/Twitter') : Args(0) {
	my( $self, $c ) = @_;
	
	my $request_token = $c->req->param('oauth_token');
    my $verifier      = $c->req->param('oauth_verifier');

    # TODO: move Tweeter App ID/Secret to general.yaml!
    my %consumer_tokens = (
		consumer_key    => 'ywz9X5JbAvN3zQDn10TQvzoJm',
		consumer_secret => 'XP9cLG53fJsR2dGecvh9E4X5xFjqhYmOZRoFy1OJQJZGVYTy9i',
	);
	
	my $oauth = $c->session->{oauth};
	#$c->log->debug('=== OAuth RESPONSE ================');
	#$c->log->debug($oauth->{token});
	#$c->log->debug($oauth->{token_secret});
	#$c->log->debug($oauth->{r});
	
	my $twitter = Net::Twitter::Lite::WithAPIv1_1->new(ssl => 1, %consumer_tokens);
	$twitter->request_token($oauth->{token});
	$twitter->request_token_secret($oauth->{token_secret});
	
	my($access_token, $access_token_secret, $uid, $name) =
		$twitter->request_access_token(verifier => $verifier);
   
	# TODO: use a transaction!
	my $user_pmb = $c->model('DB::UsersPmb')->find( { twitter_id => $uid } );
	
	if (!$user_pmb) {
		$c->session->{social_info} = {
			email => undef,
			name => $name,
			facebook_id => undef,
			twitter_id => $uid
		};

		$c->res->redirect( $c->uri_for( '/auth/social_signup' ) );
	} else {
		$c->session->{user_pmb} = {
			id => $user_pmb->id->id,
			ci => $user_pmb->ci,
			facebook_id => $user_pmb->facebook_id,
			twitter_id => $user_pmb->twitter_id
		};
		
		$c->authenticate( { email => $user_pmb->id->email }, 'no_password' );

		# send the user to their page
		$c->detach( 'redirect_on_signin', [ $c->session->{oauth}{r} ] );
	}
}

=head2 social_signup

Asks the user to confirm data returned from facebook/twitter and signs up the user.

=cut

sub social_signup : Path('/auth/social_signup') : Args(0) {
	my ( $self, $c ) = @_;
	
	my $social_info = $c->session->{social_info};
	
	my $name = $social_info->{name};
	my $email = $social_info->{email};
	my $facebook_id = $social_info->{facebook_id};
	my $twitter_id = $social_info->{twitter_id};
	
	$c->log->debug("============= Name: $name");
	$c->log->debug("============= Email: $email");
	$c->log->debug("============= FUID: $facebook_id");
	$c->log->debug("============= TUID: $twitter_id");
	
	$name = $c->req->param('fullname') if $c->req->param('fullname');
	$email = $c->req->param('email') if $c->req->param('email');
	my $ci = $c->req->param('ci') if $c->req->param('ci');

	$c->stash->{fullname} = $name;
	$c->stash->{email} = $email;
	$c->stash->{ci} = $ci;

    # check that the email is valid - otherwise flag an error
    my $raw_email = lc( $email || '' );

    my $email_checker = Email::Valid->new(
        -mxcheck  => 1,
        -tldcheck => 1,
        -fqdn     => 1,
    );

    my $good_email = $email_checker->address($raw_email);
    if ( !$good_email ) {
        $c->stash->{email} = $raw_email;
        $c->stash->{email_error} =
          $raw_email ? $email_checker->details : 'missing';
        return;
    }

	if ($name and $good_email and $ci and ($facebook_id or $twitter_id)) {
		my $user = $c->model('DB::User')->find_or_create({ email => $good_email });
		
		if ( $user ) {
			my $token_data = {
				id => $user->id, 
				facebook_id => $facebook_id,
				twitter_id => $twitter_id,
				name => $name,
				email => $good_email,
				ci => $ci
			};
			
			my $token_social_sign_up = $c->model("DB::Token")->create( {
				scope => 'email_sign_in/social',
				data => {
					%$token_data,
					r => $c->session->{oauth}{r}
				}
			} );

			$c->session->{social_info} = undef;
			
			$c->stash->{token} = $token_social_sign_up->token;
			$c->send_email( 'login.txt', { to => $good_email } );
			$c->stash->{template} = 'auth/token.html';

			#$user->name( $name );
		
			#my $user_pmb = $c->model('DB::UsersPmb')->create( { 
				#id => $user->id, 
				#facebook_id => $facebook_id,
				#twitter_id => $twitter_id,
				#ci => $ci } );
				
			#$user_pmb->update;
			#$user->update;
			
			#$c->session->{social_info} = undef;		
			#$c->session->{user_pmb} = $user_pmb;	
			#$c->authenticate( { email => $email }, 'no_password' );

			## send the user to their page
			#$c->detach( 'redirect_on_signin', [ $c->session->{oauth}{r} ] );
		}
		#} else {
			#$c->stash->{email_error} = 'inuse';
		#}
	}
}

=head2 token

Handle the 'email_sign_in' tokens. Find the account for the email address
(creating if needed), authenticate the user and delete the token.

=cut

sub token : Path('/M') : Args(1) {
    my ( $self, $c, $url_token ) = @_;

    # retrieve the token
    my $token_obj = $url_token
      ? $c->model('DB::Token')->find( {
          scope => 'email_sign_in', token => $url_token
        } )
      : undef;

	if ( $token_obj ) {
		# Sign out in case we are another user
		$c->logout();

		# find or create the user related to the token.
		my $data = $token_obj->data;
		my $user = $c->model('DB::User')->find_or_create( { email => $data->{email} } );
		$user->name( $data->{name} ) if $data->{name};
		$user->password( $data->{password}, 1 ) if $data->{password};
		$user->update;
		$c->authenticate( { email => $user->email }, 'no_password' );

		$token_obj->delete;

		# send the user to their page
		$c->detach( 'redirect_on_signin', [ $data->{r} ] );
    
	} else {
		# retrieve the social token or return
		my $token_obj = $url_token
		  ? $c->model('DB::Token')->find( {
			  scope => 'email_sign_in/social', token => $url_token
			} )
		  : undef;

		if ( !$token_obj ) {
			$c->stash->{token_not_found} = 1;
			return;
		}
			
		my $data = $token_obj->data;
		
		#$c->log->debug($_) for keys $data;
		#$c->log->debug($_) for values $data;
		
		my $user = $c->model('DB::User')->find_or_create( { email => $data->{email} } );
		$user->name( $data->{name} );
		$user->update;
		
		my $user_pmb = $c->model('DB::UsersPmb')->find_or_create( { id => $data->{id} } );
		$user_pmb->facebook_id( $data->{facebook_id} ) if $data->{facebook_id};
		$user_pmb->twitter_id( $data->{twitter_id} ) if $data->{twitter_id};
		$user_pmb->ci( $data->{ci} );
		$user_pmb->update;
		
		$c->session->{user_pmb} = {
			id => $user_pmb->id->id,
			ci => $user_pmb->ci,
			facebook_id => $user_pmb->facebook_id,
			twitter_id => $user_pmb->twitter_id
		};
		
		$c->log->debug('============> User id (session): '.$c->session->{user_pmb}->{id});
		$c->authenticate( { email => $data->{email} }, 'no_password' );

		$token_obj->delete;

		## send the user to their page
		$c->detach( 'redirect_on_signin', [ $data->{r} ] );
		
	}
}

=head2 redirect_on_signin

Used after signing in to take the person back to where they were.

=cut


sub redirect_on_signin : Private {
    my ( $self, $c, $redirect ) = @_;
    $redirect = 'my' unless $redirect;
    
    if ( $c->cobrand->moniker eq 'zurich' ) {
        $redirect = 'my' if $redirect eq 'admin';
        $redirect = 'admin' if $c->user->from_body;
    }
    
    #$c->log->debug("===> Redirect $redirect");
    #$c->log->debug('===> Redirect url '.$c->uri_for( "/$redirect" ));
    
    $c->res->redirect( $c->uri_for( "/$redirect" ) );
}

=head2 redirect

Used when trying to view a page that requires sign in when you're not.

=cut

sub redirect : Private {
    my ( $self, $c ) = @_;

    my $uri = $c->uri_for( '/auth', { r => $c->req->path } );
    $c->res->redirect( $uri );
    $c->detach;

}

=head2 change_password

Let the user change their password.

=cut

sub change_password : Local {
    my ( $self, $c ) = @_;

    $c->detach( 'redirect' ) unless $c->user;

    # FIXME - CSRF check here
    # FIXME - minimum criteria for passwords (length, contain number, etc)

    # If not a post then no submission
    return unless $c->req->method eq 'POST';

    # get the passwords
    my $new     = $c->req->param('new_password') // '';
    my $confirm = $c->req->param('confirm')      // '';

    # check for errors
    my $password_error =
       !$new && !$confirm ? 'missing'
      : $new ne $confirm ? 'mismatch'
      :                    '';

    if ($password_error) {
        $c->stash->{password_error} = $password_error;
        $c->stash->{new_password}   = $new;
        $c->stash->{confirm}        = $confirm;
        return;
    }

    # we should have a usable password - save it to the user
    $c->user->obj->update( { password => $new } );
    $c->stash->{password_changed} = 1;

}

=head2 sign_out

Log the user out. Tell them we've done so.

=cut

sub sign_out : Local {
    my ( $self, $c ) = @_;
    $c->logout();
}

sub ajax_sign_in : Path('ajax/sign_in') {
    my ( $self, $c ) = @_;

    my $return = {};
    if ( $c->forward( 'sign_in' ) ) {
        $return->{name} = $c->user->name;
    } else {
        $return->{error} = 1;
    }

    my $body = JSON->new->utf8(1)->encode( $return );
    $c->res->content_type('application/json; charset=utf-8');
    $c->res->body($body);

    return 1;
}

sub ajax_sign_out : Path('ajax/sign_out') {
    my ( $self, $c ) = @_;

    $c->logout();

    my $body = JSON->new->utf8(1)->encode( { signed_out => 1 } );
    $c->res->content_type('application/json; charset=utf-8');
    $c->res->body($body);

    return 1;
}

sub ajax_check_auth : Path('ajax/check_auth') {
    my ( $self, $c ) = @_;

    my $code = 401;
    my $data = { not_authorized => 1 };

    if ( $c->user ) {
        $data = { name => $c->user->name };
        $code = 200;
    }

    my $body = JSON->new->utf8(1)->encode( $data );
    $c->res->content_type('application/json; charset=utf-8');
    $c->res->code($code);
    $c->res->body($body);

    return 1;
}

=head2 check_auth

Utility page - returns a simple message 'OK' and a 200 response if the user is
authenticated and a 'Unauthorized' / 401 reponse if they are not.

Mainly intended for testing but might also be useful for ajax calls.

=cut

sub check_auth : Local {
    my ( $self, $c ) = @_;

    # choose the response
    my ( $body, $code )    #
      = $c->user
      ? ( 'OK', 200 )
      : ( 'Unauthorized', 401 );

    # set the response
    $c->res->body($body);
    $c->res->code($code);

    # NOTE - really a 401 response should also contain a 'WWW-Authenticate'
    # header but we ignore that here. The spec is not keeping up with usage.

    return;
}

__PACKAGE__->meta->make_immutable;

1;
