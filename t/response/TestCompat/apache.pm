package TestCompat::apache;

# Apache->"method" and Apache::"function" compat layer tests

# these tests are all run and validated on the server side.

use strict;
use warnings FATAL => 'all';

use Apache::TestUtil;
use Apache::Test;

use Apache::compat ();
use Apache::Constants qw(DIR_MAGIC_TYPE :common :response);

sub handler {
    my $r = shift;

    plan $r, tests => 11;

    $r->send_http_header('text/plain');

    ### Apache-> tests
    my $fh = Apache->gensym;
    ok t_cmp('GLOB', ref($fh), "Apache->gensym");

    ok t_cmp(1, Apache->module('mod_perl.c'),
             "Apache::module('mod_perl.c')");
    ok t_cmp(0, Apache->module('mod_ne_exists.c'),
             "Apache::module('mod_ne_exists.c')");


    ok t_cmp(Apache::exists_config_define('MODPERL2'),
             Apache->define('MODPERL2'),
             'Apache->define');

    ok t_cmp('PerlResponseHandler',
             Apache::current_callback(),
             'inside PerlResponseHandler');

    t_server_log_error_is_expected();
    Apache::log_error("Apache::log_error test ok");
    ok 1;

    # explicitly imported
    ok t_cmp("httpd/unix-directory", DIR_MAGIC_TYPE,
             'DIR_MAGIC_TYPE');

    # :response is ignored, but is now aliased in :common
    ok t_cmp("302", REDIRECT,
             'REDIRECT');

    # from :common
    ok t_cmp("401", AUTH_REQUIRED,
             'AUTH_REQUIRED');

    ok t_cmp("0", OK,
             'OK');

    my $admin = $r->server->server_admin;
    Apache->httpd_conf('ServerAdmin foo@bar.com');
    ok t_cmp('foo@bar.com', $r->server->server_admin,
             'Apache->httpd_conf');
    $r->server->server_admin($admin);

    OK;
}

1;

__END__
# so we can test whether send_httpd_header() works fine
PerlOptions +ParseHeaders