package Apache::ParseSource;

use strict;
use Apache::Build ();
use Config ();

our $VERSION = '0.01';

BEGIN {
    unless ($0 eq '-e') {
        my $filter = join '::', __PACKAGE__, 'cscan_filter';
        my $cpp = join ' ', $^X, '-M'.__PACKAGE__, '-e', $filter, '--';
        (tied %Config::Config)->{cppstdin} = $cpp;
    }
}

sub new {
    my $class = shift;
    #$C::Scan::Warn = 1;
    bless {
        config => Apache::Build->new,
    }, $class;
}

sub config {
    shift->{config};
}

sub parse {
    my $self = shift;

    $self->{scan_filename} = $self->generate_cscan_file;

    $self->{c} = $self->scan;
}

sub DESTROY {
    my $self = shift;
    unlink $self->{scan_filename}
}

{
    package Apache::ParseSource::Scan;

    our @ISA = qw(C::Scan);

    sub get {
        local $SIG{__DIE__} = \&Carp::confess;
        shift->SUPER::get(@_);
    }
}

sub scan {
    require C::Scan;
    require Carp;

    my $self = shift;

    my $c = C::Scan->new(filename => $self->{scan_filename});

    $c->set(includeDirs => $self->config->includes);

    bless $c, 'Apache::ParseSource::Scan';
}

sub generate_cscan_file {
    my $self = shift;

    require File::Find;

    my $dir = $self->config->apxs(-q => 'INCLUDEDIR');

    unless (-d $dir) {
        die "could not find include directory";
    }

    my @includes;
    my $unwanted = join '|', qw(ap_listen internal);
    File::Find::finddepth({
                           wanted => sub {
                               return unless /\.h$/;
                               return if /($unwanted)/o;
                               my $dir = $File::Find::dir;
                               push @includes, "$dir/$_";
                           },
                           follow => 1,
                          }, $dir);

    my $filename = '.apache_includes';

    open my $fh, '>', $filename or die "can't open $filename: $!";
    for (@includes) {
        print $fh qq(\#include "$_"\n);
    }
    close $fh;

    return $filename;
}

sub get_functions {
    my $self = shift;

    my $key = 'parsed_fdecls';
    return $self->{$key} if $self->{$key};

    my $c = $self->{c};

    my $fdecls = $c->get($key);

    my %seen;
    my $wanted = join '|', qw(ap_ apr_ apu_);

    my @functions;

    for my $entry (@$fdecls) {
        my($rtype, $name, $args) = @$entry;
        next unless $name =~ /^($wanted)/o;
        next if $seen{$name}++;

        my $func = {
           name => $name,
           return_type => $rtype,
           args => [map {
               { type => $_->[0], name => $_->[1] }
           } @$args],
        };

        push @functions, $func;
    }

    $self->{$key} = \@functions;
}

sub get_structs {
    my $self = shift;

    my $key = 'typedef_structs';
    return $self->{$key} if $self->{$key};

    my $c = $self->{c};

    my $typedef_structs = $c->get($key);

    my %seen;
    my $prefix = join '|', qw(ap_ apr_ apu_);
    my $other  = join '|', qw(_rec module);

    my @structures;

    while (my($type, $elts) = each %$typedef_structs) {
        next unless $type =~ /^($prefix)/o or $type =~ /($other)$/o;

        next if $seen{$type}++;

        my $struct = {
           type => $type,
           elts => [map {
               { type => $_->[0], name => $_->[2] }
           } @$elts],
        };

        push @structures, $struct;
    }

    $self->{$key} = \@structures;
}

sub write_functions_pm {
    my $self = shift;
    my $file = shift || 'FunctionTable.pm';
    my $name = shift || 'Apache::FunctionTable';

    $self->write_pm($file, $name, $self->get_functions);
}

sub write_structs_pm {
    my $self = shift;
    my $file = shift || 'StructureTable.pm';
    my $name = shift || 'Apache::StructureTable';

    $self->write_pm($file, $name, $self->get_structs);
}

sub write_pm {
    my($self, $file, $name, $data) = @_;

    require Data::Dumper;
    local $Data::Dumper::Indent = 1;

    if (-d "lib/Apache") {
        $file = "lib/Apache/$file";
    }

    open my $pm, '>', $file or die "open $file: $!";

    my $dump = Data::Dumper->new([$data],
                                 [$name])->Dump;

    my $package = __PACKAGE__;
    my $date = scalar localtime;

    print $pm <<EOF;
package $name;

# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# ! WARNING: generated by $package/$VERSION
# !          $date
# !          do NOT edit, any changes will be lost !
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

$dump

1;
EOF
    close $pm;
}

#rewrite some constructs that C::Scan cannot parse
sub cscan_filter {
    chomp(my $include = scalar <STDIN>);

    my $command = "echo \'$include\' | $Config::Config{cppstdin} @ARGV|";

    open my $cmd, $command or die;

    my %typedef;

    my $apache_file = 0;
    my %typedef_aliases =
      (cmd_parms_struct => 'cmd_parms',
       command_struct => 'command_rec',
       module_struct => 'module');

    my $alias_re = join '|', keys %typedef_aliases;

    while (<$cmd>) {
        #C::Scan cannot parse this
        s/const\s+char\s*\*\s+const\s*\*/const char **/g;

        s/\b($alias_re)\b/$typedef_aliases{$1}/o;

        if (m(^\s*\#\s*	        # Leading hash
              (line\s*)?	# 1: Optional line
              ([0-9]+)\s*	# 2: Line number
              (.*)		# 3: The rest
             )x) {
            my $file = $3;
            $file = $1 if $file =~ /"(.*)"/;
            $apache_file = ($file =~ m:apache-2\.0: or $file =~ /\.c$/);
            #only rewrite forward typedef struct declarations for apache files
            print;
        } elsif (s/typedef\s+(const\s+char\s+\*\s*)(\w+)/typedef ($1)$2/) {
            #C::Scan cannot parse this construct without ()'s
            print;
        } elsif ($apache_file and /^\s*typedef\s+struct\s+(\w+)\s+(\w+)\;/ and $1 eq $2) {
            $typedef{$1} = 1;
            #rewrite forward typedef struct declaration (done below)
            print;
        } elsif (/^\s*struct\s+(\w+)\s+\{/ and $typedef{$1}) {
            my $name = $1;
            s/^\s*struct\s+\w+/typedef struct/;
            print;
            while (my $line = <$cmd>) {
                if ($line =~ s/^\s*\}\;\s*$/\} $name\;/) {
                    print $line;
                    last;
                }
                print $line;
            }
        } else {
            print;
        }
    }

    close $cmd;
}

1;
__END__
