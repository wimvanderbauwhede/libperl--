package Library::Build;

use 5.006;
use strict;
use warnings FATAL => 'all';

our $VERSION = 0.003;

use Carp ();
use Module::Load ();

use Library::Build::Config ();

sub new {
	my ($class, $name, $version, $meta) = @_;
	my $self = {
		name    => $name,
		version => $version,
	};
	my $new_class = '_Singletons::' . (0 + $self);    # See Advanced Perl, or Class::SingletonMethods
	no strict 'refs';
	@{ $new_class . '::ISA' } = ($class);
	return bless $self, $new_class;
}

sub _peek_action {
	my $meta_arguments = shift;
	for my $arguments (map { $meta_arguments->{$_} } qw/argv envs/) {
		for my $argument (@{$arguments}) {
			return $argument if not $argument =~ m/ ^ -- /xms;
		}
	}
	return 'build';
}

sub _parse_option {
	my ($self, $options, $argument_list) = @_;
	my $argument = shift @{$argument_list};
	if ($argument eq '--') {
		push @{ $self->{arguments} }, @{$argument_list};
		last;
	}
	if ($argument =~ / \A -- (.+) \z /xms) {
		my $cb = $self->{argument_callback}{$1};
		if ($cb) {
			$cb->($options, $1, $argument_list);
		}
		else {
			Carp::croak "Unknown option '$1'";
		}
	}
	else {
		push @{ $self->{arguments} }, $argument;
	}
	return;
}

sub parse {
	my ($self, $meta_arguments) = @_;
	my %meta_arguments = %{$meta_arguments};
	@{ $meta_arguments{envs} } = split / /, $ENV{PERL_MB_OPT} if not defined $meta_arguments{envs} and $ENV{PERL_MB_OPT};

	my $action = _peek_action(\%meta_arguments);
	$self->stash('action', $action);

	@{ $meta_arguments{config} } = Library::Build::Config::read_config($action);

	my %options;
	for my $argument_list (map { $meta_arguments{$_} } qw/config cached envs argv/) {
		while ($argument_list && @{$argument_list}) {
			$self->_parse_option(\%options, $argument_list);
		}
	}
	while (my ($key, $value) = each %options) {
		$self->stash($key, $value);
	}
	return;
}

sub name {
	my $self = shift;
	return $self->{name};
}

sub version {
	my $self = shift;
	return $self->{version};
}

sub stash {
	my ($self, $name, $value) = @_;
	if (@_ > 2) {
		$self->{stash}{$name} = $value;
	}
	return $self->{stash}{$name};
}

sub register_actions {
	my ($self, %action_map) = @_;
	while (my ($name, $sub) = each %action_map) {
		unshift @{ $self->{action_map}{$name} }, $sub;
	}
	return;
}

sub inject_method {
	my ($self, %methods) = @_;
	while (my ($name, $sub) = each %methods) {
		Carp::croak "method for '$name' is not a method" if not ref($sub) eq 'CODE';
		no strict 'refs';
		*{ ref($self) . "::$name" } = $sub;
	}
	return;
}

my @stash_default_callbacks = (
	sub {
		my ($options, $name, undef) = @_;
		$options->{$name}++;
	},
	sub {
		my ($options, $name, $arguments) = @_;
		$options->{$name} = shift @{$arguments};
	},
	sub {
		my ($options, $name, $arguments) = @_;
		push @{ $options->{$name} }, shift @{$arguments};
	}
);

sub register_argument {
	my ($self, $name, $destination) = @_;
	$self->{argument_callback}{$name} = ref($destination) ? $destination : $stash_default_callbacks[$destination];
	return;
}

sub register_help {
	my ($self, %what) = @_;
	while (my ($command, $description) = each %what) {
		$self->{help_for}{$command} = $description;
	}
	return;
}

sub mixin {
	my ($self, @modules) = @_;
	for my $module (@modules) {
		next if $self->{mixed_in}{$module}++;
		Module::Load::load($module);
		my $method = "$module\::mixin";
		$self->$method();
	}
	return;
}

sub dispatch {
	my ($self, @action_names) = @_;
	Carp::croak 'No action defined' if not @action_names;
	for my $action_name (@action_names) {
		next if $self->{dispatched}{$action_name}++;
		my $action_ref = $self->{action_map}{$action_name} or Carp::croak "No action '$action_name' defined";
		$self->dispatch_next($action_ref);
	}
	return;
}

sub dispatch_next {
	my ($self, $action_ref) = @_;
	if (@{$action_ref}) {
		my ($action_sub, @action_rest) = @{$action_ref};
		$action_sub->($self, \@action_rest);
	}
	return;
}

sub dispatch_default {
	my $self = shift;
	$self->dispatch($self->stash('action'));
	return;
}

sub DESTROY {
	my $self = shift;
	delete $_Singletons::{ 0 + $self . '::' };
	return;
}

1;
