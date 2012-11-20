#!/usr/bin/perl

use strict;
use warnings;

use DBI;
use DBD::Pg;
use DBIx::Connector;
use JSON;

package TrustlyApi;

BEGIN
{
    require Exporter;
    require TrustlyApi::DBConnection;
    our $VERSION = 1.00;
    our @ISA = qw(Exporter);
    our @EXPORT = qw(create_error_object create_result_object);
}

sub _sign_object
{
    my ($dbc, $method, $object, $uuid) = @_;

    my $jsondata = JSON::to_json($object);
    my $result = $dbc->execute('SELECT signature FROM OpenSSL_Sign(_method := $1, _jsondata := $2, _uuid := $3) AS f(signature)',
                                $method, $jsondata, $uuid);

    if (!defined $result->{rows} || (scalar @{$result->{rows}}) != 1)
    {
        # Signing failed.  This should practically never happen after a
        # successful call.
        return undef;
    }

    return $result->{rows}->[0]->{signature};
}

sub _get_json_result
{
    my $result = shift;

    my $row = $result->{rows}->[0];
    my $key = (keys %{$row})[0];
    return JSON::from_json($row->{$key});
}

sub create_result_object
{
    my ($dbc, $method_call, $function_call, $result) = @_;

    my $resultobj;
    if ($function_call->{returns_json})
    {
        # extract the JSON as a perl hashref from the result object
        $resultobj = _get_json_result($result);
    }
    elsif (!$function_call->{proretset})
    {
        # If the function doesn't return a set, we need to do some additional
        # processing:
        #  - If the result contains only one column, don't return any column
        #    information; just the scalar result
        #
        #  - If the result contains more than one column, just pull it it from
        #    the array and return it as-is, with the column information.
        
        my $num_cols = scalar keys %{$result->{rows}->[0]};
        if ($num_cols == 1)
        {
            my @values = values %{$result->{rows}->[0]};
            $resultobj = $values[0];
        }
        else
        {
            $resultobj = $result->{rows}->[0];
        }
    }
    else
    {
        $resultobj = $result->{rows};
    }

    # No need for any special processing for v1 calls, api_call() will have
    # signed the result already.

    return $resultobj;
}

sub _get_api_error_code
{
    my ($dbc, $error) = @_;

    # XXX this query should probably be cached

    my $result = $dbc->execute('SELECT error, code FROM get_api_error_code($1)', $error);
    if (!defined $result->{rows} || $result->{num_rows} == 0)
    {
        # Use ERROR_UNKNOWN if this isn't a code the client is supposed to see
        # or an error happened while trying to look up the code.  Sending out
        # ERROR_UNKNOWN if something went wrong in the database is probably not
        # ideal, but there's not much we can do..
        return undef;
    }
    else
    {
        my $error = $result->{rows}->[0]->{error};
        my $code = $result->{rows}->[0]->{code};
        return [$error, $code];
    }
}

sub create_error_object
{
    my ($dbc, $method_call, $function_call, $errmessage) = @_;

    my $errcode;
    my $error;

    print STDERR "API error: $errmessage\n";

    if ($errmessage =~ /^(ERROR:  )?(ERROR_[A-Z_]+)\b/)
    {
        $error = $2;
        ($error, $errcode) = _get_api_error_code($dbc, $error);
    }

    # if we haven't yet determined an error code, use ERROR_UNKNOWN
    if (!defined $errcode)
    {
        $errmessage = 'ERROR_UNKNOWN';
        $errcode = 620;
    }

    my $errorobj =
        {
            name => "JSONRPCError",
            message => $errmessage,
            code => $errcode
        };

    # If this is a v1 API call, we need to sign the error object.
    if ($method_call->{is_v1_api_call})
    {
        my $uuid = $method_call->{params}->{UUID};
        my $method = $method_call->{method};
        my $data = { message => $errmessage, code => $errcode };
        my $signature = _sign_object($dbc, $method_call->{method}, $data, $uuid);

        $errorobj->{error} =
            {
                signature => $signature,
                uuid => $uuid,
                method => $method,
                data => $data
            };
    }

    return $errorobj;
}

END
{
}

1;