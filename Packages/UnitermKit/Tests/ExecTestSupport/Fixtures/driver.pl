#!/usr/bin/perl
# A synthetic exec driver for uniterm's tests. Usage:
#
#   driver.pl MODE TYPE SCHEMA [ARGUMENTS...]
#
# TYPE and SCHEMA go into the driver's hello. SCHEMA is "major.minor". MODE picks how the driver behaves or misbehaves, so
# each test names the one behavior it proves.
use strict;
use warnings;
use JSON::PP;

$| = 1;
STDERR->autoflush(1);

my ($mode, $type, $schema, @rest) = @ARGV;
my $json = JSON::PP->new->canonical->allow_nonref;
my $next_id = 1;

# The exec protocol version this driver speaks.
my $protocol = 0;

sub send_message { print $json->encode($_[0]), "\n"; }

sub hello {
    my ($protocol, $schema_version) = @_;
    my ($major, $minor) = split /\./, $schema_version;
    send_message({type => "hello", protocol => $protocol + 0, applet => $type,
                  schema => [$major + 0, ($minor // 0) + 0]});
}

sub command {
    my ($name, $arguments) = @_;
    send_message({type => "command", id => $next_id++, name => $name,
                  arguments => $arguments // {}});
}

# Sends a message a test wrote out whole, such as a layout or a command to another pane. It gets
# the next request ID.
sub request {
    my ($message) = @_;
    send_message({%$message, id => $next_id++});
}

# Reads the app's hello first, the way a real driver checks it before it sends anything.
sub read_app_hello {
    my $line = <STDIN>;
    return undef unless defined $line;
    return $json->decode($line);
}

# Messages held for the user's Next, oldest first. Each press sends the next one.
my @on_advance;

# Replaces each {"pane": "leafN"} under a layout with the pane at leaf N of an earlier reply.
sub resolve_leaves {
    my ($node, $panes) = @_;
    if (ref $node eq "HASH") {
        if (defined $node->{pane} && $node->{pane} =~ /^leaf(\d+)$/) {
            $node->{pane} = $panes->[$1];
        }
        resolve_leaves($_, $panes) for values %$node;
    } elsif (ref $node eq "ARRAY") {
        resolve_leaves($_, $panes) for @$node;
    }
}

# Answers events and logs every line from the app to stderr, until stdin ends.
sub serve {
    while (my $line = <STDIN>) {
        chomp $line;
        my $message = $json->decode($line);
        # Each line goes out as one string. STDERR is unbuffered, so a list would be one write per
        # piece, and a reader can wake between them.
        print STDERR "got $message->{type}" . (defined $message->{name} ? " $message->{name}" : "")
            . (defined $message->{error} ? " $message->{error}{code}" : "") . "\n";
        print STDERR "error message: $message->{error}{message}\n" if defined $message->{error};
        print STDERR "event data: " . $json->encode($message->{data}) . "\n"
            if $message->{type} eq "event";
        if ($message->{type} eq "reply" && ref $message->{result} eq "HASH"
            && exists $message->{result}{text}) {
            print STDERR "clipboard text: " . ($message->{result}{text} // "(none)") . "\n";
        }

        if ($message->{type} eq "event" && $message->{name} eq "advance-requested") {
            command("show-slide", {index => $message->{data}{from} + 1});
            request(shift @on_advance) if @on_advance;
        }
    }
}

if ($mode eq "script") {
    read_app_hello();
    hello($protocol, $schema);
    print STDERR "driver ready\n";
    for my $message (map { $json->decode($_) } @rest) {
        if (defined $message->{type}) {
            request($message);
        } else {
            command($message->{name}, $message->{arguments});
        }
    }
    serve();
} elsif ($mode eq "layout") {
    # Sends the layout in its first argument and waits for the answer. Each later argument is a
    # command for the pane at its "leaf" index in the reply, sent once the layout is published. A
    # message marked "later" waits for the user's Next instead, one per press. A later message with
    # a type is sent as it is, such as a second layout, with "leafN" panes resolved.
    my ($layout, @commands) = @rest;
    read_app_hello();
    hello($protocol, $schema);
    my $id = $next_id;
    request({type => "layout", layout => $json->decode($layout)});
    my $panes;
    while (my $line = <STDIN>) {
        my $message = $json->decode($line);
        next unless defined $message->{id} && $message->{id} == $id;
        if ($message->{type} eq "reply") {
            $panes = $message->{result}{panes};
            print STDERR "layout published\n";
        } else {
            print STDERR "layout refused: $message->{error}{message}\n";
        }
        last;
    }
    if ($panes) {
        for my $command (map { $json->decode($_) } @commands) {
            my $leaf = delete $command->{leaf};
            my $later = delete $command->{later};
            my $message;
            if (defined $command->{type}) {
                resolve_leaves($command, $panes);
                $message = $command;
            } else {
                $message = {%$command, type => "command", pane => $panes->[$leaf]};
            }
            if ($later) {
                push @on_advance, $message;
            } else {
                request($message);
            }
        }
    }
    serve();
} elsif ($mode eq "pending-order") {
    # Sends a command that waits (ID 1), one that answers at once (ID 2), and one that satisfies the
    # wait (ID 3). Replies match by ID, so the wait's reply comes after the second command's. It
    # reports the order the replies arrived in.
    read_app_hello();
    hello($protocol, $schema);
    command("wait-for-notes", {contains => "go"});
    command("set-notes", {text => "not yet"});
    command("set-notes", {text => "go"});
    my @order;
    while (my $line = <STDIN>) {
        my $message = $json->decode($line);
        next unless $message->{type} eq "reply" || $message->{type} eq "error";
        push @order, $message->{id};
        print STDERR "reply order: @order\n" if @order == 3;
    }
} elsif ($mode eq "clipboard-sizes") {
    # Writes one clipboard text of each size in the arguments, every byte a control character, so
    # the JSON encoder escapes each one to six bytes. A test sizes the text, not the argv.
    read_app_hello();
    hello($protocol, $schema);
    request({type => "clipboard-write", text => "\x01" x $_}) for @rest;
    command("status", {});
    serve();
} elsif ($mode eq "env") {
    my ($file) = @rest;
    read_app_hello();
    hello($protocol, $schema);
    open(my $out, ">", $file) or die "cannot write $file: $!";
    print $out "cwd=", `/bin/pwd`;
    print $out "$_=$ENV{$_}\n" for sort keys %ENV;
    close($out);
    serve();
} elsif ($mode eq "hello-protocol") {
    read_app_hello();
    hello($rest[0], $schema);
    command("set-deck", {titles => ["skew"]});
    serve();
} elsif ($mode eq "hello-schema") {
    read_app_hello();
    hello($protocol, $rest[0]);
    command("set-deck", {titles => ["skew"]});
    serve();
} elsif ($mode eq "command-first") {
    command("set-deck", {titles => ["early"]});
    hello($protocol, $schema);
    serve();
} elsif ($mode eq "refuse") {
    my $app = read_app_hello();
    send_message({type => "error",
                  error => {code => "unsupported-version",
                            message => "this driver needs exec protocol 9, not $app->{protocol}"}});
    command("set-deck", {titles => ["refused"]});
    exit 3;
} elsif ($mode eq "malformed") {
    read_app_hello();
    hello($protocol, $schema);
    print "this is not json\n";
    serve();
} elsif ($mode eq "stale-hello") {
    # A hello from another protocol, with keys and a schema shape the current protocol lacks.
    read_app_hello();
    send_message({type => "hello", protocol => $rest[0] + 0, applet => $type,
                  schema => {major => 1, minor => 0}, extra => "from a later hello"});
    command("set-deck", {titles => ["stale"]});
    serve();
} elsif ($mode eq "unknown-key") {
    # A command with a key this protocol does not have, such as one that a changed meaning renamed.
    read_app_hello();
    hello($protocol, $schema);
    send_message({type => "command", id => $next_id++, name => "set-deck",
                  arguments => {titles => ["misread"]}, tab => 3});
    serve();
} elsif ($mode eq "unknown-type") {
    read_app_hello();
    hello($protocol, $schema);
    send_message({type => "retire-me", id => $next_id++});
    serve();
} elsif ($mode eq "partial") {
    read_app_hello();
    hello($protocol, $schema);
    print '{"type":"command","id":1,"name":"set-de';
    exit 0;
} elsif ($mode eq "long-line") {
    read_app_hello();
    hello($protocol, $schema);
    print "x" x (2 * 1024 * 1024);
    sleep 60;
} elsif ($mode eq "flood") {
    read_app_hello();
    hello($protocol, $schema);
    while (1) { command("status", {}); }
} elsif ($mode eq "stall") {
    read_app_hello();
    hello($protocol, $schema);
    print STDERR "stalling\n";
    sleep 600;
} elsif ($mode eq "partial-stderr") {
    # Writes part of a line with no newline, then goes quiet and stays connected.
    read_app_hello();
    hello($protocol, $schema);
    print STDERR "loading";
    serve();
} elsif ($mode eq "stderr-flood") {
    read_app_hello();
    hello($protocol, $schema);
    print STDERR "flood line $_\n" for 1 .. 100000;
    # The pause lets the app drain the bounded ingress, so the last line is not one of the dropped.
    select(undef, undef, undef, 0.5);
    print STDERR "flood done\n";
    serve();
} elsif ($mode eq "ignore-term") {
    $SIG{TERM} = "IGNORE";
    read_app_hello();
    hello($protocol, $schema);
    sleep 600 while 1;
} elsif ($mode eq "grandchild") {
    # A background child in the driver's group that ignores SIGTERM and holds stdout open.
    my ($file) = @rest;
    read_app_hello();
    my $child = fork();
    if ($child == 0) {
        $SIG{TERM} = "IGNORE";
        sleep 600 while 1;
        exit 0;
    }
    open(my $out, ">", $file) or die "cannot write $file: $!";
    print $out "$child\n";
    close($out);
    hello($protocol, $schema);
    serve();
} elsif ($mode eq "exit") {
    read_app_hello();
    hello($protocol, $schema);
    exit($rest[0] // 0);
} elsif ($mode eq "drain") {
    # A healthy driver that reads everything and answers nothing, the baseline for the stall.
    read_app_hello();
    hello($protocol, $schema);
    1 while <STDIN>;
} elsif ($mode eq "silent") {
    1 while <STDIN>;
} else {
    die "unknown mode $mode\n";
}
