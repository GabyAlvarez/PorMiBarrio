package FixMyStreet::App::Controller::Contact;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

FixMyStreet::App::Controller::Contact - Catalyst Controller

=head1 DESCRIPTION

Contact us page

=head1 METHODS

=cut

=head2 index

=cut

sub index : Path : Args(0) {
    my ( $self, $c ) = @_;

    return unless
           $c->forward('setup_request')
        && $c->forward('determine_contact_type');

#    my ($q, $errors, $field_errors) = @_;
#    my @errors = @$errors;
#    my %field_errors = %{$field_errors};
#    push @errors, _('There were problems with your report. Please see below.') if (scalar keys %field_errors);
#    my @vars = qw(name em subject message);
#    my %input = map { $_ => $q->param($_) || '' } @vars;
#    my %input_h = map { $_ => $q->param($_) ? ent($q->param($_)) : '' } @vars;
#    my $out = '';

    #    my $cobrand = Page::get_cobrand($q);
    #    my $form_action = Cobrand::url($cobrand, '/contact', $q);
    #
    #    my $intro = '';
    #    my $item_title = '';
    #    my $item_body = '';
    #    my $item_meta = '';
    #    my $hidden_vals = '';

#    my $cobrand_form_elements = Cobrand::form_elements(Page::get_cobrand($q), 'contactForm', $q);
#    my %vars = (
#      header => $header,
#      errors => $errors,
#      intro => $intro,
#      item_title => $item_title,
#      item_meta => $item_meta,
#      item_body => $item_body,
#      hidden_vals => $hidden_vals,
#      form_action => $form_action,
#      input_h => \%input_h,
#      field_errors => \%field_errors,
#      label_name => _('Your name:'),
#      label_email => _('Your&nbsp;email:'),
#      label_subject => _('Subject:'),
#      label_message => _('Message:'),
#      label_submit => _('Post'),
#      contact_details => contact_details($q),
#      cobrand_form_elements => $cobrand_form_elements
#    );
#    $out .= Page::template_include('contact', $q, Page::template_root($q), %vars);
#    return $out;
}

sub submit : Path('submit') : Args(0) {
    my ( $self, $c ) = @_;

    return unless 
           $c->forward('setup_request')
        && $c->forward('validate');
}

sub determine_contact_type : Private {
    my ( $self, $c ) = @_;

    my $id        = $c->req->param('id');
    my $update_id = $c->req->param('update_id');
    $id        = undef unless $id        && $id        =~ /^[1-9]\d*$/;
    $update_id = undef unless $update_id && $update_id =~ /^[1-9]\d*$/;

    if ($id) {
        my $problem = $c->model('DB::Problem')->find(
            { id => $id },
            {
                'select' => [
                    'title', 'detail', 'name',
                    'anonymous',
                    'user_id',
                    {
                        extract => 'epoch from confirmed',
                        -as     => 'confirmed'
                    }
                ]
            }
        );

        if ($update_id) {

#             my $u = dbh()->selectrow_hashref(
#            'select comment.text, comment.name, problem.title, extract(epoch from comment.confirmed) as confirmed
#            from comment, problem where comment.id=?
#            and comment.problem_id = problem.id
#            and comment.problem_id=?', {}, $update_id ,$id);
        }
        elsif ($problem) {
            $c->stash->{problem} = $problem;
        }
    }

    return 1;
}

sub validate : Private {
    my ( $self, $c ) = @_;

    my ( %field_errors, @errors );
    my %required = (
        name    => _('Please give your name'),
        em      => _('Please give your email'),
        subject => _('Please give a subject'),
        message => _('Please write a message')
    );

    foreach my $field ( keys %required ) {
        $field_errors{$field} = $required{$field}
          unless $c->req->param($field) =~ /\S/;
    }

    unless ( $field_errors{em} ) {
        $field_errors{em} = _('Please give a valid email address')
          if !mySociety::EmailUtil::is_valid_email( $c->req->param('em') );
    }

    push @errors, _('Illegal ID')
      if $c->req->param('id') && $c->req->param('id') !~ /^[1-9]\d*$/
          or $c->req->param('update_id')
          && $c->req->param('update_id') !~ /^[1-9]\d*$/;

    if ( @errors or scalar keys %field_errors ) {
        $c->stash->{errors}       = \@errors;
        $c->stash->{field_errors} = \%field_errors;
        $c->go('index');
    }
}

sub setup_request : Private {
    my ( $self, $c ) = @_;

    $c->stash->{contact_email} = $c->cobrand->contact_email;
    $c->stash->{contact_email} =~ s/\@/&#64;/;

    for my $param (qw/em subject message/) {
        $c->stash->{$param} = $c->req->param($param);
    }

    # name is already used in the stash for the app class name
    $c->stash->{form_name} = $c->req->param('name');

    return 1;
}

=head1 AUTHOR

Struan Donald

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
