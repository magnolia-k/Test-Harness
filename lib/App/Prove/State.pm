package App::Prove::State;

use strict;
use vars qw($VERSION @ISA);

use File::Find;
use File::Spec;
use Carp;

use App::Prove::State::Result;
use App::Prove::State::Result::Test;
use TAP::Parser::YAMLish::Reader ();
use TAP::Parser::YAMLish::Writer ();
use TAP::Base;

@ISA = qw( TAP::Base );

use constant IS_WIN32 => ( $^O =~ /^(MS)?Win32$/ );
use constant NEED_GLOB => IS_WIN32;

=head1 NAME

App::Prove::State - State storage for the C<prove> command.

=head1 VERSION

Version 3.14

=cut

$VERSION = '3.14';

=head1 DESCRIPTION

The C<prove> command supports a C<--state> option that instructs it to
store persistent state across runs. This module implements that state
and the operations that may be performed on it.

=head1 SYNOPSIS

    # Re-run failed tests
    $ prove --state=fail,save -rbv

=cut

=head1 METHODS

=head2 Class Methods

=head3 C<new>

=cut

# override TAP::Base::new:
sub new {
    my $class = shift;
    my %args = %{ shift || {} };

    my $self = bless {
        _ => App::Prove::State::Result->new(
            {   tests      => {},
                generation => 1,
            }
        ),
        select    => [],
        seq       => 1,
        store     => delete $args{store},
        extension => delete $args{extension} || '.t',
    }, $class;

    my $store = $self->{store};
    $self->load($store)
      if defined $store && -f $store;

    return $self;
}

=head2 C<extension>

Get or set the extension files must have in order to be considered
tests. Defaults to '.t'.

=cut

sub extension {
    my $self = shift;
    $self->{extension} = shift if @_;
    return $self->{extension};
}

=head2 C<results>

Get the results of the last test run.  Returns an L<App::Prove::State::Result>
object.

=cut

sub results { shift->{_} || App::Prove::State::Result->new }

=head2 C<commit>

Save the test results. Should be called after all tests have run.

=cut

sub commit {
    my $self = shift;
    if ( $self->{should_save} && defined( my $store = $self->{store} ) ) {
        $self->save($store);
    }
}

=head2 Instance Methods

=head3 C<apply_switch>

Apply a list of switch options to the state.

=over

=item C<last>

Run in the same order as last time

=item C<failed>

Run only the failed tests from last time

=item C<passed>

Run only the passed tests from last time

=item C<all>

Run all tests in normal order

=item C<hot>

Run the tests that most recently failed first

=item C<todo>

Run the tests ordered by number of todos.

=item C<slow>

Run the tests in slowest to fastest order.

=item C<fast>

Run test tests in fastest to slowest order.

=item C<new>

Run the tests in newest to oldest order.

=item C<old>

Run the tests in oldest to newest order.

=item C<save>

Save the state on exit.

=back

=cut

sub apply_switch {
    my $self = shift;
    my @opts = @_;

    my $last_gen = $self->results->generation - 1;
    my $now      = $self->get_time;

    my @switches = map { split /,/ } @opts;

    my %handler = (
        last => sub {
            $self->_select(
                where => sub { $_->generation >= $last_gen },
                order => sub { $_->sequence }
            );
        },
        failed => sub {
            $self->_select(
                where => sub { $_->result != 0 },
                order => sub { -$_->result }
            );
        },
        passed => sub {
            $self->_select( where => sub { $_->result == 0 } );
        },
        all => sub {
            $self->_select();
        },
        todo => sub {
            $self->_select(
                where => sub { $_->num_todo != 0 },
                order => sub { -$_->num_todo; }
            );
        },
        hot => sub {
            $self->_select(
                where => sub { defined $_->last_fail_time },
                order => sub { $now - $_->last_fail_time }
            );
        },
        slow => sub {
            $self->_select( order => sub { -$_->elapsed } );
        },
        fast => sub {
            $self->_select( order => sub { $_->elapsed } );
        },
        new => sub {
            $self->_select( order => sub { -$_->mtime } );
        },
        old => sub {
            $self->_select( order => sub { $_->mtime } );
        },
        save => sub {
            $self->{should_save}++;
        },
        adrian => sub {
            unshift @switches, qw( hot all save );
        },
    );

    while ( defined( my $ele = shift @switches ) ) {
        my ( $opt, $arg )
          = ( $ele =~ /^([^:]+):(.*)/ )
          ? ( $1, $2 )
          : ( $ele, undef );
        my $code = $handler{$opt}
          || croak "Illegal state option: $opt";
        $code->($arg);
    }
}

sub _select {
    my ( $self, %spec ) = @_;
    push @{ $self->{select} }, \%spec;
}

=head3 C<get_tests>

Given a list of args get the names of tests that should run

=cut

sub get_tests {
    my $self    = shift;
    my $recurse = shift;
    my @argv    = @_;
    my %seen;

    my @selected = $self->_query;

    unless ( @argv || @{ $self->{select} } ) {
        @argv = $recurse ? '.' : 't';
        croak qq{No tests named and '@argv' directory not found}
          unless -d $argv[0];
    }

    push @selected, $self->_get_raw_tests( $recurse, @argv ) if @argv;
    return grep { !$seen{$_}++ } @selected;
}

sub _query {
    my $self = shift;
    if ( my @sel = @{ $self->{select} } ) {
        warn "No saved state, selection will be empty\n"
          unless $self->results->num_tests;
        return map { $self->_query_clause($_) } @sel;
    }
    return;
}

sub _query_clause {
    my ( $self, $clause ) = @_;
    my @got;
    my $results = $self->results;
    my $where = $clause->{where} || sub {1};

    # Select
    for my $name ( $results->test_names ) {
        next unless -f $name;
        local $_ = $results->test($name);
        push @got, $name if $where->();
    }

    # Sort
    if ( my $order = $clause->{order} ) {
        @got = map { $_->[0] }
          sort {
                 ( defined $b->[1] <=> defined $a->[1] )
              || ( ( $a->[1] || 0 ) <=> ( $b->[1] || 0 ) )
          } map {
            [   $_,
                do { local $_ = $results->test($_); $order->() }
            ]
          } @got;
    }

    return @got;
}

sub _get_raw_tests {
    my $self    = shift;
    my $recurse = shift;
    my @argv    = @_;
    my @tests;

    # Do globbing on Win32.
    @argv = map { glob "$_" } @argv if NEED_GLOB;
    my $extension = $self->{extension};

    for my $arg (@argv) {
        if ( '-' eq $arg ) {
            push @argv => <STDIN>;
            chomp(@argv);
            next;
        }

        push @tests,
            sort -d $arg
          ? $recurse
              ? $self->_expand_dir_recursive( $arg, $extension )
              : glob( File::Spec->catfile( $arg, "*$extension" ) )
          : $arg;
    }
    return @tests;
}

sub _expand_dir_recursive {
    my ( $self, $dir, $extension ) = @_;

    my @tests;
    find(
        {   follow      => 1,      #21938
            follow_skip => 2,
            wanted      => sub {
                -f 
                  && /\Q$extension\E$/
                  && push @tests => $File::Find::name;
              }
        },
        $dir
    );
    return @tests;
}

=head3 C<observe_test>

Store the results of a test.

=cut

sub observe_test {
    my ( $self, $test, $parser ) = @_;
    $self->_record_test(
        $test->[0],
        scalar( $parser->failed ) + ( $parser->has_problems ? 1 : 0 ),
        scalar( $parser->todo ), $parser->start_time, $parser->end_time,
    );
}

# Store:
#     last fail time
#     last pass time
#     last run time
#     most recent result
#     most recent todos
#     total failures
#     total passes
#     state generation

sub _record_test {
    my ( $self, $name, $fail, $todo, $start_time, $end_time ) = @_;
    my $test = $self->results->test($name);

    $test->sequence( $self->{seq}++ );
    $test->generation( $self->results->generation );

    $test->run_time($end_time);
    $test->result($fail);
    $test->num_todo($todo);
    $test->elapsed( $end_time - $start_time );

    if ($fail) {
        $test->total_failures( $test->total_failures + 1 );
        $test->last_fail_time($end_time);
    }
    else {
        $test->total_passes( $test->total_passes + 1 );
        $test->last_pass_time($end_time);
    }
}

=head3 C<save>

Write the state to a file.

=cut

sub save {
    my ( $self, $name ) = @_;
    my $writer = TAP::Parser::YAMLish::Writer->new;
    local *FH;
    open FH, ">$name" or croak "Can't write $name ($!)";
    $writer->write( $self->results->raw, \*FH );
    close FH;
}

=head3 C<load>

Load the state from a file

=cut

sub load {
    my ( $self, $name ) = @_;
    my $reader = TAP::Parser::YAMLish::Reader->new;
    local *FH;
    open FH, "<$name" or croak "Can't read $name ($!)";

    # XXX this is temporary
    $self->{_} = App::Prove::State::Result->new(
        $reader->read(
            sub {
                my $line = <FH>;
                defined $line && chomp $line;
                return $line;
            }
        )
    );

    # $writer->write( $self->{tests} || {}, \*FH );
    close FH;
    $self->_regen_seq;
    $self->_prune_and_stamp;
    $self->results->generation( $self->results->generation + 1 );
}

sub _prune_and_stamp {
    my $self = shift;

    my $results = $self->results;
    my @tests   = $self->results->tests;
    for my $test (@tests) {
        my $name = $test->name;
        if ( my @stat = stat $name ) {
            $test->mtime( $stat[9] );
        }
        else {
            $results->remove($name);
        }
    }
}

sub _regen_seq {
    my $self = shift;
    for my $test ( $self->results->tests ) {
        $self->{seq} = $test->sequence + 1
          if defined $test->sequence && $test->sequence >= $self->{seq};
    }
}

1;
