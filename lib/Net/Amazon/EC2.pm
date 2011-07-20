package Net::Amazon::EC2;
use Moose;

use strict;
use vars qw($VERSION);

use XML::Simple;
use LWP::UserAgent;
use Digest::HMAC_SHA1;
use URI;
use MIME::Base64 qw(encode_base64 decode_base64);
use HTTP::Date qw(time2isoz);
use Params::Validate qw(validate SCALAR ARRAYREF);
use Data::Dumper qw(Dumper);

use Net::Amazon::EC2::DescribeImagesResponse;
use Net::Amazon::EC2::DescribeKeyPairsResponse;
use Net::Amazon::EC2::GroupSet;
use Net::Amazon::EC2::InstanceState;
use Net::Amazon::EC2::IpPermission;
use Net::Amazon::EC2::LaunchPermission;
use Net::Amazon::EC2::LaunchPermissionOperation;
use Net::Amazon::EC2::ProductCode;
use Net::Amazon::EC2::ProductInstanceResponse;
use Net::Amazon::EC2::ReservationInfo;
use Net::Amazon::EC2::RunningInstances;
use Net::Amazon::EC2::SecurityGroup;
use Net::Amazon::EC2::UserData;
use Net::Amazon::EC2::UserIdGroupPair;
use Net::Amazon::EC2::IpRange;
use Net::Amazon::EC2::KeyPair;
use Net::Amazon::EC2::DescribeImageAttribute;
use Net::Amazon::EC2::ConsoleOutput;
use Net::Amazon::EC2::Errors;
use Net::Amazon::EC2::Error;
use Net::Amazon::EC2::ConfirmProductInstanceResponse;
use Net::Amazon::EC2::DescribeAddress;
use Net::Amazon::EC2::AvailabilityZone;
use Net::Amazon::EC2::BlockDeviceMapping;
use Net::Amazon::EC2::PlacementResponse;
use Net::Amazon::EC2::Volume;
use Net::Amazon::EC2::Attachment;
use Net::Amazon::EC2::Snapshot;
use Net::Amazon::EC2::BundleInstanceResponse;
use Net::Amazon::EC2::Region;
use Net::Amazon::EC2::ReservedInstance;
use Net::Amazon::EC2::ReservedInstanceOffering;
use Net::Amazon::EC2::MonitoredInstance;
use Net::Amazon::EC2::InstancePassword;
use Net::Amazon::EC2::SnapshotAttribute;
use Net::Amazon::EC2::CreateVolumePermission;
use Net::Amazon::EC2::AvailabilityZoneMessage;
use Net::Amazon::EC2::StateReason;
use Net::Amazon::EC2::InstanceBlockDeviceMapping;
use Net::Amazon::EC2::InstanceStateChange;
use Net::Amazon::EC2::DescribeInstanceAttributeResponse;
use Net::Amazon::EC2::EbsInstanceBlockDeviceMapping;
use Net::Amazon::EC2::EbsBlockDevice;
use Net::Amazon::EC2::TagSet;
use Net::Amazon::EC2::DescribeTags;

$VERSION = '0.15';

=head1 NAME

Net::Amazon::EC2 - Perl interface to the Amazon Elastic Compute Cloud (EC2)
environment.

=head1 VERSION

This document describes version 0.14 of Net::Amazon::EC2, released
February 1st, 2010. This module is coded against the Query API version of the '2011-01-01' 
version of the EC2 API last updated January 1st, 2011.

=head1 SYNOPSIS

 use Net::Amazon::EC2;

 my $ec2 = Net::Amazon::EC2->new(
	AWSAccessKeyId => 'PUBLIC_KEY_HERE', 
	SecretAccessKey => 'SECRET_KEY_HERE'
 );

 # Start 1 new instance from AMI: ami-XXXXXXXX
 my $instance = $ec2->run_instances(ImageId => 'ami-XXXXXXXX', MinCount => 1, MaxCount => 1);

 my $running_instances = $ec2->describe_instances;

 foreach my $reservation (@$running_instances) {
    foreach my $instance ($reservation->instances_set) {
        print $instance->instance_id . "\n";
    }
 }

 my $instance_id = $instance->instances_set->[0]->instance_id;

 print "$instance_id\n";

 # Terminate instance

 my $result = $ec2->terminate_instances(InstanceId => $instance_id);

If an error occurs while communicating with EC2, the return value of these methods will be a Net::Amazon::EC2::Errors object.

=head1 DESCRIPTION

This module is a Perl interface to Amazon's Elastic Compute Cloud. It uses the Query API to communicate with Amazon's Web Services framework.

=head1 CLASS METHODS

=head2 new(%params)

This is the constructor, it will return you a Net::Amazon::EC2 object to work with.  It takes these parameters:

=over

=item AWSAccessKeyId (required)

Your AWS access key.

=item SecretAccessKey (required)

Your secret key, WARNING! don't give this out or someone will be able to use your account and incur charges on your behalf.

=item region (optional)

The region to run the API requests through. The options are:

=over

=item * us-east-1 - Nothern Virginia

=item * us-west-1 - Northern California

=item * eu-west-1 - Ireland

=back

=item debug (optional)

A flag to turn on debugging. It is turned off by default

=back

=cut

has 'AWSAccessKeyId'	=> ( is => 'ro', isa => 'Str', required => 1 );
has 'SecretAccessKey'	=> ( is => 'ro', isa => 'Str', required => 1 );
has 'debug'				=> ( is => 'ro', isa => 'Str', required => 0, default => 0 );
has 'signature_version'	=> ( is => 'ro', isa => 'Int', required => 1, default => 1 );
has 'version'			=> ( is => 'ro', isa => 'Str', required => 1, default => '2011-01-01' );
has 'region'			=> ( is => 'ro', isa => 'Str', required => 1, default => 'us-east-1' );
has 'timestamp'			=> ( 
	is			=> 'ro', 
	isa			=> 'Str', 
	required	=> 1, 
	default		=> sub { 
		my $ts = time2isoz(); 
		chop($ts); 
		$ts .= '.000Z'; 
		$ts =~ s/\s+/T/g; 
		return $ts; 
	} 
);
has 'base_url'			=> ( 
	is			=> 'ro', 
	isa			=> 'Str', 
	required	=> 1,
	lazy		=> 1,
	default		=> sub {
		return 'http://' . $_[0]->region . '.ec2.amazonaws.com';
	}
);

sub _sign {
	my $self						= shift;
	my %args						= @_;
	my $action						= delete $args{Action};
	my %sign_hash					= %args;
	$sign_hash{AWSAccessKeyId}		= $self->AWSAccessKeyId;
	$sign_hash{Action}				= $action;
	$sign_hash{Timestamp}			= $self->timestamp;
	$sign_hash{Version}				= $self->version;
	$sign_hash{SignatureVersion}	= $self->signature_version;
	my $sign_this;

	# The sign string must be alphabetical in a case-insensitive manner.
	foreach my $key (sort { lc($a) cmp lc($b) } keys %sign_hash) {
		$sign_this .= $key . $sign_hash{$key};
	}

	$self->_debug("QUERY TO SIGN: $sign_this");
	my $encoded = $self->_hashit($self->SecretAccessKey, $sign_this);

	my $uri = URI->new($self->base_url);
	my %params = (
		Action				=> $action,
		SignatureVersion	=> $self->signature_version,
		AWSAccessKeyId		=> $self->AWSAccessKeyId,
		Timestamp			=> $self->timestamp,
		Version				=> $self->version,
		Signature			=> $encoded,
		%args
	);
	
	my $ur	= $uri->as_string();
	$self->_debug("GENERATED QUERY URL: $ur");
	my $ua	= LWP::UserAgent->new();
	my $res	= $ua->post($ur, \%params);
	# We should force <item> elements to be in an array
	my $xs	= XML::Simple->new(ForceArray => qr/(?:item|Errors)/i, KeyAttr => '');
	my $xml;
	
	# Check the result for connectivity problems, if so throw an error
 	if ($res->code >= 500) {
 		my $message = $res->status_line;
		$xml = <<EOXML;
<xml>
	<RequestID>N/A</RequestID>
	<Errors>
		<Error>
			<Code>HTTP POST FAILURE</Code>
			<Message>$message</Message>
		</Error>
	</Errors>
</xml>
EOXML

 	}
	else {
		$xml = $res->content();
	}

	my $ref = $xs->XMLin($xml);
	warn Dumper($ref) . "\n\n" if $self->debug == 1;

	return $ref;
}

sub _parse_errors {
	my $self		= shift;
	my $errors_xml	= shift;
	
	my $es;
	my $request_id = $errors_xml->{RequestID};

	foreach my $e (@{$errors_xml->{Errors}}) {
		my $error = Net::Amazon::EC2::Error->new(
			code	=> $e->{Error}{Code},
			message	=> $e->{Error}{Message},
		);
		
		push @$es, $error;
	}
	
	my $errors = Net::Amazon::EC2::Errors->new(
		request_id	=> $request_id,
		errors		=> $es,
	);

	foreach my $error (@{$errors->errors}) {
		$self->_debug("ERROR CODE: " . $error->code . " MESSAGE: " . $error->message . " FOR REQUEST: " . $errors->request_id);
	}
	
	return $errors;	
}

sub _debug {
	my $self	= shift;
	my $message	= shift;
	
	if ((grep { defined && length} $self->debug) && $self->debug == 1) {
		print "$message\n\n\n\n";
	}
}

# HMAC sign the query with the aws secret access key and base64 encodes the result.
sub _hashit {
	my $self								= shift;
	my ($secret_access_key, $query_string)	= @_;
	my $hashed								= Digest::HMAC_SHA1->new($secret_access_key);
	$hashed->add($query_string);
	
	my $encoded = encode_base64($hashed->digest, '');

	return $encoded;
}

=head1 OBJECT METHODS

=head2 allocate_address()

Acquires an elastic IP address which can be associated with an instance to create a movable static IP. Takes no arguments

Returns the IP address obtained.

=cut

sub allocate_address {
	my $self = shift;

	my $xml = $self->_sign(Action  => 'AllocateAddress');

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		return $xml->{publicIp};
	}
}

=head2 associate_address(%params)

Associates an elastic IP address with an instance. It takes the following arguments:

=over

=item InstanceId (required)

The instance id you wish to associate the IP address with

=item PublicIp (required)

The IP address to associate with

=back

Returns true if the association succeeded.

=cut

sub associate_address {
	my $self = shift;
	my %args = validate( @_, {
		InstanceId		=> { type => SCALAR },
		PublicIp 		=> { type => SCALAR },
	});
	
	my $xml = $self->_sign(Action  => 'AssociateAddress', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}
}

=head2 attach_volume(%params)

Attach a volume to an instance.

=over

=item VolumeId (required)

The volume id you wish to attach.

=item InstanceId (required)

The instance id you wish to attach the volume to.

=item Device (required)

The device id you want the volume attached as.

=back

Returns a Net::Amazon::EC2::Attachment object containing the resulting volume status.

=cut

sub attach_volume {
	my $self = shift;
	my %args = validate( @_, {
		VolumeId	=> { type => SCALAR },
		InstanceId	=> { type => SCALAR },
		Device		=> { type => SCALAR },
	});

	my $xml = $self->_sign(Action  => 'AttachVolume', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $attachment = Net::Amazon::EC2::Attachment->new(
			volume_id	=> $xml->{volumeId},
			status		=> $xml->{status},
			instance_id	=> $xml->{instanceId},
			attach_time	=> $xml->{attachTime},
			device		=> $xml->{device},
		);
		
		return $attachment;
	}
}

=head2 authorize_security_group_ingress(%params)

This method adds permissions to a security group.  It takes the following parameters:

=over

=item GroupName (required)

The name of the group to add security rules to.

=item SourceSecurityGroupName (requred when authorizing a user and group together)

Name of the group to add access for.

=item SourceSecurityGroupOwnerId (required when authorizing a user and group together)

Owner of the group to add access for.

=item IpProtocol (required when adding access for a CIDR)

IP Protocol of the rule you are adding access for (TCP, UDP, or ICMP)

=item FromPort (required when adding access for a CIDR)

Beginning of port range to add access for.

=item ToPort (required when adding access for a CIDR)

End of port range to add access for.

=item CidrIp (required when adding access for a CIDR)

The CIDR IP space we are adding access for.

=back

Adding a rule can be done in two ways: adding a source group name + source group owner id, or, by Protocol + start port + end port + CIDR IP.  The two are mutally exclusive.

Returns 1 if rule is added successfully.

=cut

sub authorize_security_group_ingress {
	my $self = shift;
	my %args = validate( @_, {
		GroupName					=> { type => SCALAR },
		SourceSecurityGroupName 	=> { 
			type => SCALAR,
			depends => ['SourceSecurityGroupOwnerId'],
			optional => 1 ,
		},
		SourceSecurityGroupOwnerId	=> { type => SCALAR, optional => 1 },
		IpProtocol 					=> { 
			type => SCALAR,
			depends => ['FromPort', 'ToPort', 'CidrIp'],
			optional => 1 
		},
		FromPort 					=> { type => SCALAR, optional => 1 },
		ToPort 						=> { type => SCALAR, optional => 1 },
		CidrIp						=> { type => SCALAR, optional => 1 },
	});
	
	
	my $xml = $self->_sign(Action  => 'AuthorizeSecurityGroupIngress', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}
}

=head2 bundle_instance(%params)

Bundles the Windows instance. This procedure is not applicable for Linux and UNIX instances.

NOTE NOTE NOTE This is not well tested as I don't run windows instances

=over

=item InstanceId (required)

The ID of the instance to bundle.

=item Storage.S3.Bucket (required)

The bucket in which to store the AMI. You can specify a bucket that you already own or a new bucket that Amazon EC2 creates on your behalf. If you specify a bucket that belongs to someone else, Amazon EC2 returns an error.

=item Storage.S3.Prefix (required)

Specifies the beginning of the file name of the AMI.

=item Storage.S3.AWSAccessKeyId (required)

The Access Key ID of the owner of the Amazon S3 bucket.

=item Storage.S3.UploadPolicy (required)

An Amazon S3 upload policy that gives Amazon EC2 permission to upload items into Amazon S3 on the user's behalf.

=item Storage.S3.UploadPolicySignature (required)

The signature of the Base64 encoded JSON document.

JSON Parameters: (all are required)

expiration - The expiration of the policy. Amazon recommends 12 hours or longer.
conditions - A list of restrictions on what can be uploaded to Amazon S3. Must contain the bucket and ACL conditions in this table.
bucket - The bucket to store the AMI. 
acl - This must be set to ec2-bundle-read.

=back

Returns a Net::Amazon::EC2::BundleInstanceResponse object

=cut

sub bundle_instance {
	my $self = shift;
	my %args = validate( @_, {
		'InstanceId'						=> { type => SCALAR },
		'Storage.S3.Bucket'					=> { type => SCALAR },
		'Storage.S3.Prefix'					=> { type => SCALAR },
		'Storage.S3.AWSAccessKeyId'			=> { type => SCALAR },
		'Storage.S3.UploadPolicy'			=> { type => SCALAR },
		'Storage.S3.UploadPolicySignature'	=> { type => SCALAR },
	});

	my $xml = $self->_sign(Action  => 'BundleInstance', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $bundle = Net::Amazon::EC2::BundleInstanceResponse->new(
			instance_id					=> $xml->{bundleInstanceTask}{instanceId},
			bundle_id					=> $xml->{bundleInstanceTask}{bundleId},
			state						=> $xml->{bundleInstanceTask}{state},
			start_time					=> $xml->{bundleInstanceTask}{startTime},
			update_time					=> $xml->{bundleInstanceTask}{updateTime},
			progress					=> $xml->{bundleInstanceTask}{progress},
			s3_bucket					=> $xml->{bundleInstanceTask}{storage}{S3}{bucket},
			s3_prefix					=> $xml->{bundleInstanceTask}{storage}{S3}{bucket},
			s3_aws_access_key_id		=> $xml->{bundleInstanceTask}{storage}{S3}{bucket},
			s3_upload_policy			=> $xml->{bundleInstanceTask}{storage}{S3}{bucket},
			s3_policy_upload_signature	=> $xml->{bundleInstanceTask}{storage}{S3}{bucket},
			bundle_error_code			=> $xml->{bundleInstanceTask}{error}{code},
			bundle_error_message		=> $xml->{bundleInstanceTask}{error}{message},
		);
		
		return $bundle;
	}
}

=head2 cancel_bundle_task(%params)

Cancels the bundle task. This procedure is not applicable for Linux and UNIX instances.

=over

=item BundleId (required)

The ID of the bundle task to cancel.

=back

Returns a Net::Amazon::EC2::BundleInstanceResponse object

=cut

sub cancel_bundle_task {
	my $self = shift;
	my %args = validate( @_, {
		'BundleId'							=> { type => SCALAR },
	});

	my $xml = $self->_sign(Action  => 'CancelBundleTask', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $bundle = Net::Amazon::EC2::BundleInstanceResponse->new(
			instance_id					=> $xml->{bundleInstanceTask}{instanceId},
			bundle_id					=> $xml->{bundleInstanceTask}{bundleId},
			state						=> $xml->{bundleInstanceTask}{state},
			start_time					=> $xml->{bundleInstanceTask}{startTime},
			update_time					=> $xml->{bundleInstanceTask}{updateTime},
			progress					=> $xml->{bundleInstanceTask}{progress},
			s3_bucket					=> $xml->{bundleInstanceTask}{storage}{S3}{bucket},
			s3_prefix					=> $xml->{bundleInstanceTask}{storage}{S3}{bucket},
			s3_aws_access_key_id		=> $xml->{bundleInstanceTask}{storage}{S3}{bucket},
			s3_upload_policy			=> $xml->{bundleInstanceTask}{storage}{S3}{bucket},
			s3_policy_upload_signature	=> $xml->{bundleInstanceTask}{storage}{S3}{bucket},
			bundle_error_code			=> $xml->{bundleInstanceTask}{error}{code},
			bundle_error_message		=> $xml->{bundleInstanceTask}{error}{message},
		);
		
		return $bundle;
	}
}

=head2 confirm_product_instance(%params)

Checks to see if the product code passed in is attached to the instance id, taking the following parameter:

=over

=item ProductCode (required)

The Product Code to check

=item InstanceId (required)

The Instance Id to check

=back

Returns a Net::Amazon::EC2::ConfirmProductInstanceResponse object

=cut

sub confirm_product_instance {
	my $self = shift;
	my %args = validate( @_, {
		ProductCode	=> { type => SCALAR },
		InstanceId	=> { type => SCALAR },
	});

	my $xml = $self->_sign(Action  => 'ConfirmProductInstance', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $confirm_response = Net::Amazon::EC2::ConfirmProductInstanceResponse->new(
			'return'		=> $xml->{'return'},
			owner_id		=> $xml->{ownerId},
		);
		
		return $confirm_response;
	}
}

=head2 create_image(%params)

Creates an AMI that uses an Amazon EBS root device from a "running" or "stopped" instance.

AMIs that use an Amazon EBS root device boot faster than AMIs that use instance stores. 
They can be up to 1 TiB in size, use storage that persists on instance failure, and can be stopped and started.

=over

=item InstanceId (required)

The ID of the instance.

=item Name (required)

The name of the AMI that was provided during image creation.

Note that the image name has the following constraints:

3-128 alphanumeric characters, parenthesis, commas, slashes, dashes, or underscores.

=item Description (optional)

The description of the AMI that was provided during image creation.

=item NoReboot (optional)

By default this property is set to false, which means Amazon EC2 attempts to cleanly shut down the 
instance before image creation and reboots the instance afterwards. When set to true, Amazon EC2 
does not shut down the instance before creating the image. When this option is used, file system 
integrity on the created image cannot be guaranteed. 

=back

Returns the ID of the AMI created.

=cut

sub create_image {
	my $self = shift;
	my %args = validate( @_, {
		InstanceId	=> { type => SCALAR },
		Name		=> { type => SCALAR },
		Description	=> { type => SCALAR, optional => 1 },
		NoReboot	=> { type => SCALAR, optional => 1 },
	});
		
	my $xml = $self->_sign(Action  => 'CreateImage', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		return $xml->{imageId};
	}
}

=head2 create_key_pair(%params)

Creates a new 2048 bit key pair, taking the following parameter:

=over

=item KeyName (required)

A name for this key. Should be unique.

=back

Returns a Net::Amazon::EC2::KeyPair object

=cut

sub create_key_pair {
	my $self = shift;
	my %args = validate( @_, {
		KeyName => { type => SCALAR },
	});
		
	my $xml = $self->_sign(Action  => 'CreateKeyPair', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $key_pair = Net::Amazon::EC2::KeyPair->new(
			key_name		=> $xml->{keyName},
			key_fingerprint	=> $xml->{keyFingerprint},
			key_material	=> $xml->{keyMaterial},
		);
		
		return $key_pair;
	}
}

=head2 create_security_group(%params)

This method creates a new security group.  It takes the following parameters:

=over

=item GroupName (required)

The name of the new group to create.

=item GroupDescription (required)

A short description of the new group.

=back

Returns 1 if the group creation succeeds.

=cut

sub create_security_group {
	my $self = shift;
	my %args = validate( @_, {
		GroupName				=> { type => SCALAR },
		GroupDescription 		=> { type => SCALAR },
	});
	
	
	my $xml = $self->_sign(Action  => 'CreateSecurityGroup', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}	
}

=head2 create_snapshot(%params)

Create a snapshot of a volume. It takes the following arguments:

=over

=item VolumeId (required)

The volume id of the volume you want to take a snapshot of.

=item Description (optional)

Description of the Amazon EBS snapshot.

=back

Returns a Net::Amazon::EC2::Snapshot object of the newly created snapshot.

=cut

sub create_snapshot {
	my $self = shift;
	my %args = validate( @_, {
		VolumeId	=> { type => SCALAR },
		Description	=> { type => SCALAR, optional => 1 },
	});
	
	my $xml = $self->_sign(Action  => 'CreateSnapshot', %args);

	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		unless ( grep { defined && length } $xml->{progress} and ref $xml->{progress} ne 'HASH') {
			$xml->{progress} = undef;
		}

		my $snapshot = Net::Amazon::EC2::Snapshot->new(
			snapshot_id		=> $xml->{snapshotId},
			status			=> $xml->{status},
			volume_id		=> $xml->{volumeId},
			start_time		=> $xml->{startTime},
			progress		=> $xml->{progress},
			owner_id		=> $xml->{ownerId},
			volume_size		=> $xml->{volumeSize},
			description		=> $xml->{description},
		);

  		return $snapshot;
	}
}

=head2 create_tags(%params)

Creates tags.

=over

=item ResourceId (required)

The ID of the resource to create tags

=item Tag.Key (required)

Key for a tag, may pass in a scalar or arrayref.

=item Tag.Value (required)

Value for a tag, may pass in a scalar or arrayref.

=back

Returns true if the releasing succeeded.

=cut

sub create_tags {
	my $self = shift;
	my %args = validate( @_, {
		ResourceId				=> { type => ARRAYREF | SCALAR },
		'Tag.Key'				=> { type => ARRAYREF | SCALAR },
		'Tag.Value'				=> { type => ARRAYREF | SCALAR },
	});

        if (ref ($args{'ResourceId'}) eq 'ARRAY') {
                my $keys                        = delete $args{'ResourceId'};
                my $count                       = 1;
                foreach my $key (@{$keys}) {
                        $args{"ResourceId." . $count} = $key;
                        $count++;
                }
        }
        else {
                $args{"ResourceId.1"} = delete $args{'ResourceId'};
        }

	# If we have a array ref of keys lets split them out into their Tag.n.Key format
	if (ref ($args{'Tag.Key'}) eq 'ARRAY') {
		my $keys			= delete $args{'Tag.Key'};
		my $count			= 1;
		foreach my $key (@{$keys}) {
			$args{"Tag." . $count . ".Key"} = $key;
			$count++;
		}
	}

	# If we have a array ref of values lets split them out into their Tag.n.Value format
	if (ref ($args{'Tag.Value'}) eq 'ARRAY') {
		my $values			= delete $args{'Tag.Value'};
		my $count			= 1;
		foreach my $value (@{$values}) {
			$args{"Tag." . $count . ".Value"} = $value;
			$count++;
		}
	}

	my $xml = $self->_sign(Action  => 'CreateTags', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}
}

=head2 create_volume(%params)

Creates a volume.

=over

=item Size (required)

The size in GiB of the volume you want to create.

=item SnapshotId (optional)

The optional snapshot id to create the volume from.

=item AvailabilityZone (required)

The availability zone to create the volume in.

=back

Returns true if the releasing succeeded.

=cut

sub create_volume {
	my $self = shift;
	my %args = validate( @_, {
		Size				=> { type => SCALAR },
		SnapshotId			=> { type => SCALAR, optional => 1 },
		AvailabilityZone	=> { type => SCALAR },
	});

	my $xml = $self->_sign(Action  => 'CreateVolume', %args);

	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {

		unless ( grep { defined && length } $xml->{snapshotId} and ref $xml->{snapshotId} ne 'HASH') {
			$xml->{snapshotId} = undef;
		}

		my $volume = Net::Amazon::EC2::Volume->new(
			volume_id		=> $xml->{volumeId},
			status			=> $xml->{status},
			zone			=> $xml->{availabilityZone},
			create_time		=> $xml->{createTime},
			snapshot_id		=> $xml->{snapshotId},
			size			=> $xml->{size},
		);

		return $volume;
	}
}

=head2 delete_key_pair(%params)

This method deletes a keypair.  Takes the following parameter:

=over

=item KeyName (required)

The name of the key to delete.

=back

Returns 1 if the key was successfully deleted.

=cut

sub delete_key_pair {
	my $self = shift;
	my %args = validate( @_, {
		KeyName => { type => SCALAR },
	});
		
	my $xml = $self->_sign(Action  => 'DeleteKeyPair', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}	
}

=head2 delete_security_group(%params)

This method deletes a security group.  It takes the following parameter:

=over

=item GroupName (required)

The name of the security group to delete.

=back

Returns 1 if the delete succeeded.

=cut

sub delete_security_group {
	my $self = shift;
	my %args = validate( @_, {
		GroupName => { type => SCALAR },
	});
	
	
	my $xml = $self->_sign(Action  => 'DeleteSecurityGroup', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}
}

=head2 delete_snapshot(%params)

Deletes the snapshots passed in. It takes the following arguments:

=over

=item SnapshotId (required)

Either a scalar or array ref of snapshot id's can be passed in. Will delete the corresponding
snapshots.

=back

Returns true if the deleting succeeded.

=cut

sub delete_snapshot {
	my $self = shift;
	my %args = validate( @_, {
		SnapshotId	=> { type => ARRAYREF | SCALAR },
	});

	# If we have a array ref of volumes lets split them out into their SnapshotId.n format
	if (ref ($args{SnapshotId}) eq 'ARRAY') {
		my $snapshots		= delete $args{SnapshotId};
		my $count			= 1;
		foreach my $snapshot (@{$snapshots}) {
			$args{"SnapshotId." . $count} = $snapshot;
			$count++;
		}
	}
	
	my $xml = $self->_sign(Action  => 'DeleteSnapshot', %args);

	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}
}

=head2 delete_volume(%params)

Delete a volume.

=over

=item VolumeId (required)

The volume id you wish to delete.

=back

Returns true if the deleting succeeded.

=cut

sub delete_volume {
	my $self = shift;
	my %args = validate( @_, {
		VolumeId	=> { type => SCALAR, optional => 1 },
	});

	my $xml = $self->_sign(Action  => 'DeleteVolume', %args);

	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}
}

=head2 delete_tags(%params)

Delete tags.

=over

=item ResourceId (required)

The ID of the resource to delete tags

=item Tag.Key (required)

Key for a tag, may pass in a scalar or arrayref.

=item Tag.Value (required)

Value for a tag, may pass in a scalar or arrayref.

=back

Returns true if the releasing succeeded.

=cut

sub delete_tags {
	my $self = shift;
	my %args = validate( @_, {
		ResourceId				=> { type => ARRAYREF | SCALAR },
		'Tag.Key'				=> { type => ARRAYREF | SCALAR },
		'Tag.Value'				=> { type => ARRAYREF | SCALAR, optional => 1 },
	});

	# If we have a array ref of keys lets split them out into their Tag.n.Key format
	if (ref ($args{'Tag.Key'}) eq 'ARRAY') {
		my $keys			= delete $args{'Tag.Key'};
		my $count			= 1;
		foreach my $key (@{$keys}) {
			$args{"Tag." . $count . ".Key"} = $key;
			$count++;
		}
	}

	# If we have a array ref of values lets split them out into their Tag.n.Value format
	if (ref ($args{'Tag.Value'}) eq 'ARRAY') {
		my $values			= delete $args{'Tag.Value'};
		my $count			= 1;
		foreach my $value (@{$values}) {
			$args{"Tag." . $count . ".Value"} = $value;
			$count++;
		}
	}

	my $xml = $self->_sign(Action  => 'DeleteTags', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}
}


=head2 deregister_image(%params)

This method will deregister an AMI. It takes the following parameter:

=over

=item ImageId (required)

The image id of the AMI you want to deregister.

=back

Returns 1 if the deregistering succeeded

=cut

sub deregister_image {
	my $self = shift;
	my %args = validate( @_, {
		ImageId	=> { type => SCALAR },
	});
	

	my $xml = $self->_sign(Action  => 'DeregisterImage', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}
}

=head2 describe_addresses(%params)

This method describes the elastic addresses currently allocated and any instances associated with them. It takes the following arguments:

=over

=item PublicIp (optional)

The IP address to describe. Can be either a scalar or an array ref.

=back

Returns an array ref of Net::Amazon::EC2::DescribeAddress objects

=cut

sub describe_addresses {
	my $self = shift;
	my %args = validate( @_, {
		PublicIp 		=> { type => SCALAR, optional => 1 },
	});

	# If we have a array ref of ip addresses lets split them out into their PublicIp.n format
	if (ref ($args{PublicIp}) eq 'ARRAY') {
		my $ip_addresses	= delete $args{PublicIp};
		my $count			= 1;
		foreach my $ip_address (@{$ip_addresses}) {
			$args{"PublicIp." . $count} = $ip_address;
			$count++;
		}
	}
	
	my $addresses;
	my $xml = $self->_sign(Action  => 'DescribeAddresses', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		foreach my $addy (@{$xml->{addressesSet}{item}}) {
			if (ref($addy->{instanceId}) eq 'HASH') {
				undef $addy->{instanceId};
			}
			
			my $address = Net::Amazon::EC2::DescribeAddress->new(
				public_ip	=> $addy->{publicIp},
				instance_id	=> $addy->{instanceId},
			);
			
			push @$addresses, $address;
		}
		
		return $addresses;
	}
}

=head2 describe_availability_zones(%params)

This method describes the availability zones currently available to choose from. It takes the following arguments:

=over

=item ZoneName (optional)

The zone name to describe. Can be either a scalar or an array ref.

=back

Returns an array ref of Net::Amazon::EC2::AvailabilityZone objects

=cut

sub describe_availability_zones {
	my $self = shift;
	my %args = validate( @_, {
		ZoneName	=> { type => SCALAR, optional => 1 },
	});

	# If we have a array ref of zone names lets split them out into their ZoneName.n format
	if (ref ($args{ZoneName}) eq 'ARRAY') {
		my $zone_names		= delete $args{ZoneName};
		my $count			= 1;
		foreach my $zone_name (@{$zone_names}) {
			$args{"ZoneName." . $count} = $zone_name;
			$count++;
		}
	}
	
	my $xml = $self->_sign(Action  => 'DescribeAvailabilityZones', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $availability_zones;
		foreach my $az (@{$xml->{availabilityZoneInfo}{item}}) {
			my $availability_zone_messages;
			# Create the messages for this zone
			foreach my $azm (@{$az->{messageSet}{item}}) {
				my $availability_zone_message = Net::Amazon::EC2::AvailabilityZoneMessage->new(
					message => $azm->{message},
				);
				
				push @$availability_zone_messages, $availability_zone_message;
			}
			
			my $availability_zone = Net::Amazon::EC2::AvailabilityZone->new(
				zone_name	=> $az->{zoneName},
				zone_state	=> $az->{zoneState},
				region_name	=> $az->{regionName},
				messages	=> $availability_zone_messages,
			);
			
			push @$availability_zones, $availability_zone;
		}
		
		return $availability_zones;
	}
}

=head2 describe_bundle_tasks(%params)

Describes current bundling tasks. This procedure is not applicable for Linux and UNIX instances.

=over

=item BundleId (optional)

The optional ID of the bundle task to describe.

=back

Returns a array ref of Net::Amazon::EC2::BundleInstanceResponse objects

=cut

sub describe_bundle_tasks {
	my $self = shift;
	my %args = validate( @_, {
		'BundleId'							=> { type => SCALAR, optional => 1 },
	});

	my $xml = $self->_sign(Action  => 'DescribeBundleTasks', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $bundle_tasks;
		
		foreach my $item (@{$xml->{bundleInstanceTasksSet}{item}}) {
			my $bundle = Net::Amazon::EC2::BundleInstanceResponse->new(
				instance_id					=> $item->{instanceId},
				bundle_id					=> $item->{bundleId},
				state						=> $item->{state},
				start_time					=> $item->{startTime},
				update_time					=> $item->{updateTime},
				progress					=> $item->{progress},
				s3_bucket					=> $item->{storage}{S3}{bucket},
				s3_prefix					=> $item->{storage}{S3}{bucket},
				s3_aws_access_key_id		=> $item->{storage}{S3}{bucket},
				s3_upload_policy			=> $item->{storage}{S3}{bucket},
				s3_policy_upload_signature	=> $item->{storage}{S3}{bucket},
				bundle_error_code			=> $item->{error}{code},
				bundle_error_message		=> $item->{error}{message},
			);
			
			push @$bundle_tasks, $bundle;
		}
				
		return $bundle_tasks;
	}
}

=head2 describe_image_attributes(%params)

This method pulls a list of attributes for the image id specified

=over

=item ImageId (required)

A scalar containing the image you want to get the list of attributes for.

=item Attribute (required)

A scalar containing the attribute to describe.

Valid attributes are:

=over

=item launchPermission - The AMIs launch permissions.

=item ImageId - ID of the AMI for which an attribute will be described.

=item productCodes - The product code attached to the AMI.

=item kernel - Describes the ID of the kernel associated with the AMI.

=item ramdisk - Describes the ID of RAM disk associated with the AMI.

=item blockDeviceMapping - Defines native device names to use when exposing virtual devices.

=item platform - Describes the operating system platform.

=back

=back

Returns a Net::Amazon::EC2::DescribeImageAttribute object

* NOTE: There is currently a bug in Amazon's SOAP and Query API
for when you try and describe the attributes: kernel, ramdisk, blockDeviceMapping, or platform
AWS returns an invalid response. No response yet from Amazon on an ETA for getting that bug fixed.

=cut

sub describe_image_attribute {
	my $self = shift;
	my %args = validate( @_, {
								ImageId => { type => SCALAR },
								Attribute => { type => SCALAR }
	});
		
	my $xml = $self->_sign(Action  => 'DescribeImageAttribute', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $launch_permissions;
		my $product_codes;
		my $block_device_mappings;
		
		if ( grep { defined && length } $xml->{launchPermission}{item} ) {
			foreach my $lp (@{$xml->{launchPermission}{item}}) {
				my $launch_permission = Net::Amazon::EC2::LaunchPermission->new(
					group	=> $lp->{group},
					user_id	=> $lp->{userId},
				);
				
				push @$launch_permissions, $launch_permission;
			}
		}

		if ( grep { defined && length } $xml->{productCodes}{item} ) {
			foreach my $pc (@{$xml->{productCodes}{item}}) {
				my $product_code = Net::Amazon::EC2::ProductCode->new(
					product_code	=> $pc->{productCode},
				);
				
				push @$product_codes, $product_code;
			}
		}
		
		if ( grep { defined && length } $xml->{blockDeviceMapping}{item} ) {
			foreach my $bd (@{$xml->{blockDeviceMapping}{item}}) {
				my $block_device_mapping = Net::Amazon::EC2::BlockDeviceMapping->new(
					virtual_name	=> $bd->{virtualName},
					device_name		=> $bd->{deviceName},
				);
				
				push @$block_device_mappings, $block_device_mapping;
			}
		}
		
		my $describe_image_attribute = Net::Amazon::EC2::DescribeImageAttribute->new(
			image_id			=> $xml->{imageId},
			launch_permissions	=> $launch_permissions,
			product_codes		=> $product_codes,
			kernel				=> $xml->{kernel},
			ramdisk				=> $xml->{ramdisk},
			blockDeviceMapping	=> $block_device_mappings,
			platform			=> $xml->{platform},
		);

		return $describe_image_attribute;
	}
}

=head2 describe_images(%params)

This method pulls a list of the AMIs which can be run.  The list can be modified by passing in some of the following parameters:

=over 

=item ImageId (optional)

Either a scalar or an array ref can be passed in, will cause just these AMIs to be 'described'

=item Owner (optional)

Either a scalar or an array ref can be passed in, will cause AMIs owned by the Owner's provided will be 'described'. Pass either account ids, or 'amazon' for all amazon-owned AMIs, or 'self' for your own AMIs.

=item ExecutableBy (optional)

Either a scalar or an array ref can be passed in, will cause AMIs executable by the account id's specified.  Or 'self' for your own AMIs.

=back

Returns an array ref of Net::Amazon::EC2::DescribeImagesResponse objects

=cut

sub describe_images {
	my $self = shift;
	my %args = validate( @_, {
		ImageId			=> { type => SCALAR | ARRAYREF, optional => 1 },
		Owner			=> { type => SCALAR | ARRAYREF, optional => 1 },
		ExecutableBy	=> { type => SCALAR | ARRAYREF, optional => 1 },
	});
	
	# If we have a array ref of instances lets split them out into their ImageId.n format
	if (ref ($args{ImageId}) eq 'ARRAY') {
		my $image_ids	= delete $args{ImageId};
		my $count		= 1;
		foreach my $image_id (@{$image_ids}) {
			$args{"ImageId." . $count} = $image_id;
			$count++;
		}
	}
	
	# If we have a array ref of instances lets split them out into their Owner.n format
	if (ref ($args{Owner}) eq 'ARRAY') {
		my $owners	= delete $args{Owner};
		my $count	= 1;
		foreach my $owner (@{$owners}) {
			$args{"Owner." . $count} = $owner;
			$count++;
		}
	}

	# If we have a array ref of instances lets split them out into their ExecutableBy.n format
	if (ref ($args{ExecutableBy}) eq 'ARRAY') {
		my $executors	= delete $args{ExecutableBy};
		my $count		= 1;
		foreach my $executor (@{$executors}) {
			$args{"ExecutableBy." . $count} = $executor;
			$count++;
		}
	}

	my $xml = $self->_sign(Action  => 'DescribeImages', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $images;
		
		foreach my $item (@{$xml->{imagesSet}{item}}) {
			my $product_codes;
			my $state_reason;
			my $block_device_mappings;
			
			if ( grep { defined && length } $item->{stateReason} ) {
				$state_reason = Net::Amazon::EC2::StateReason->new(
					code	=> $item->{stateReason}{code},
					message	=> $item->{stateReason}{message},
				);
			}

			if ( grep { defined && length } $item->{blockDeviceMapping} ) {
				foreach my $bdm ( @{$item->{blockDeviceMapping}{item}} ) {
					my $virtual_name;
					my $no_device;
					my $ebs_block_device_mapping;
					
					if ( grep { defined && length } $bdm->{ebs} ) {
						$ebs_block_device_mapping = Net::Amazon::EC2::EbsBlockDevice->new(
							snapshot_id				=> $bdm->{ebs}{snapshotId},
							volume_size				=> $bdm->{ebs}{volumeSize},
							delete_on_termination	=> $bdm->{ebs}{deleteOnTermination},							
						);
					}
					
					
					my $block_device_mapping = Net::Amazon::EC2::BlockDeviceMapping->new(
						device_name		=> $bdm->{deviceName},
						virtual_name	=> $virtual_name,
						ebs				=> $ebs_block_device_mapping,
						no_device		=> $no_device,
					);
					push @$block_device_mappings, $block_device_mapping;
				}
			}

			my $image = Net::Amazon::EC2::DescribeImagesResponse->new(
				image_id				=> $item->{imageId},
				image_owner_id			=> $item->{imageOwnerId},
				image_state				=> $item->{imageState},
				is_public				=> $item->{isPublic},
				image_location			=> $item->{imageLocation},
				architecture			=> $item->{architecture},
				image_type				=> $item->{imageType},
				kernel_id				=> $item->{kernelId},
				ramdisk_id				=> $item->{ramdiskId},
				platform				=> $item->{platform},
				state_reason			=> $state_reason,
				image_owner_alias		=> $item->{imageOwnerAlias},
				name					=> $item->{name},
				description				=> $item->{description},
				root_device_type		=> $item->{rootDeviceType},
				root_device_name		=> $item->{rootDeviceName},
				block_device_mapping	=> $block_device_mappings,
			);
			
			if (grep { defined && length } $item->{productCodes} ) {
				foreach my $pc (@{$item->{productCodes}{item}}) {
					my $product_code = Net::Amazon::EC2::ProductCode->new( product_code => $pc->{productCode} );
					push @$product_codes, $product_code;
				}
				
				$image->product_codes($product_codes);
			}

			
			push @$images, $image;
		}
				
		return $images;
	}
}

=head2 describe_instances(%params)

This method pulls a list of the instances which are running or were just running.  The list can be modified by passing in some of the following parameters:

=over

=item InstanceId (optional)

Either a scalar or an array ref can be passed in, will cause just these instances to be 'described'

=back

Returns an array ref of Net::Amazon::EC2::ReservationInfo objects

=cut

sub describe_instances {
	my $self = shift;
	my %args = validate( @_, {
		InstanceId => { type => SCALAR | ARRAYREF, optional => 1 },
	});
	
	# If we have a array ref of instances lets split them out into their InstanceId.n format
	if (ref ($args{InstanceId}) eq 'ARRAY') {
		my $instance_ids	= delete $args{InstanceId};
		my $count			= 1;
		foreach my $instance_id (@{$instance_ids}) {
			$args{"InstanceId." . $count} = $instance_id;
			$count++;
		}
	}
	
	my $xml = $self->_sign(Action  => 'DescribeInstances', %args);
	my $reservations;
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		foreach my $reservation_set (@{$xml->{reservationSet}{item}}) {
			my $group_sets;
			foreach my $group_arr (@{$reservation_set->{groupSet}{item}}) {
				my $group = Net::Amazon::EC2::GroupSet->new(
					group_id	=> $group_arr->{groupId},
					group_name	=> $group_arr->{groupName},
				);
				push @$group_sets, $group;
			}
	
			my $running_instances;
			foreach my $instance_elem (@{$reservation_set->{instancesSet}{item}}) {
				my $instance_state_type = Net::Amazon::EC2::InstanceState->new(
					code	=> $instance_elem->{instanceState}{code},
					name	=> $instance_elem->{instanceState}{name},
				);
				
				my $product_codes;
				my $block_device_mappings;
				my $state_reason;
				
				if (grep { defined && length } $instance_elem->{productCodes} ) {
					foreach my $pc (@{$instance_elem->{productCodes}{item}}) {
						my $product_code = Net::Amazon::EC2::ProductCode->new( product_code => $pc->{productCode} );
						push @$product_codes, $product_code;
					}
				}

				if ( grep { defined && length } $instance_elem->{blockDeviceMapping} ) {
					foreach my $bdm ( @{$instance_elem->{blockDeviceMapping}{item}} ) {
						my $ebs_block_device_mapping = Net::Amazon::EC2::EbsInstanceBlockDeviceMapping->new(
							volume_id				=> $bdm->{ebs}{volumeId},
							status					=> $bdm->{ebs}{status},
							attach_time				=> $bdm->{ebs}{attachTime},
							delete_on_termination	=> $bdm->{ebs}{deleteOnTermination},							
						);
						
						my $block_device_mapping = Net::Amazon::EC2::BlockDeviceMapping->new(
							ebs						=> $ebs_block_device_mapping,
							device_name				=> $bdm->{deviceName},
						);
						push @$block_device_mappings, $block_device_mapping;
					}
				}

				if ( grep { defined && length } $instance_elem->{stateReason} ) {
					$state_reason = Net::Amazon::EC2::StateReason->new(
						code	=> $instance_elem->{stateReason}{code},
						message	=> $instance_elem->{stateReason}{message},
					);
				}
				
				unless ( grep { defined && length } $instance_elem->{reason} and ref $instance_elem->{reason} ne 'HASH' ) {
					$instance_elem->{reason} = undef;
				}
						
				unless ( grep { defined && length } $instance_elem->{privateDnsName} and ref $instance_elem->{privateDnsName} ne 'HASH' ) {
					$instance_elem->{privateDnsName} = undef;
				}
									
				unless ( grep { defined && length } $instance_elem->{dnsName} and ref $instance_elem->{dnsName} ne 'HASH' ) {
					$instance_elem->{dnsName} = undef;
				}

				unless ( grep { defined && length } $instance_elem->{placement}{availabilityZone} and ref $instance_elem->{placement}{availabilityZone} ne 'HASH' ) {
					$instance_elem->{placement}{availabilityZone} = undef;
				}
				
				my $placement_response = Net::Amazon::EC2::PlacementResponse->new( availability_zone => $instance_elem->{placement}{availabilityZone} );

				my $tag_sets;
				foreach my $tag_arr (@{$instance_elem->{tagSet}{item}}) {
					my $key = $tag_arr->{key};
					my $value = (ref $tag_arr->{value} eq '') ? $tag_arr->{value} : '';
					my $tag = Net::Amazon::EC2::TagSet->new(
						key => $key,
						value => $value,
					);
					push @$tag_sets, $tag;
				}
				my $group_sets_instance;
				foreach my $group_arr (@{$instance_elem->{groupSet}{item}}) {
					my $group = Net::Amazon::EC2::GroupSet->new(
						group_id	=> $group_arr->{groupId},
						group_name	=> $group_arr->{groupName},
					);
					push @$group_sets_instance, $group;
				}

				my $running_instance = Net::Amazon::EC2::RunningInstances->new(
					ami_launch_index		=> $instance_elem->{amiLaunchIndex},
					dns_name				=> $instance_elem->{dnsName},
					image_id				=> $instance_elem->{imageId},
					kernel_id				=> $instance_elem->{kernelId},
					ramdisk_id				=> $instance_elem->{ramdiskId},
					instance_id				=> $instance_elem->{instanceId},
					instance_state			=> $instance_state_type,
					instance_type			=> $instance_elem->{instanceType},
					key_name				=> $instance_elem->{keyName},
					launch_time				=> $instance_elem->{launchTime},
					placement				=> $placement_response,
					private_dns_name		=> $instance_elem->{privateDnsName},
					reason					=> $instance_elem->{reason},
					platform				=> $instance_elem->{platform},
					monitoring				=> $instance_elem->{monitoring}{state},
					subnet_id				=> $instance_elem->{subnetId},
					vpc_id					=> $instance_elem->{vpcId},
					private_ip_address		=> $instance_elem->{privateIpAddress},
					ip_address				=> $instance_elem->{ipAddress},
					architecture			=> $instance_elem->{architecture},
					root_device_name		=> $instance_elem->{rootDeviceName},
					root_device_type		=> $instance_elem->{rootDeviceType},
					block_device_mapping	=> $block_device_mappings,
					state_reason			=> $state_reason,
					tag_set					=> $tag_sets,
					group_set				=> $group_sets_instance,
					instance_lifecycle		=> $instance_elem->{instanceLifecycle},
					spot_instance_request_id	=> $instance_elem->{spotInstanceRequestId},
					virtualization_type		=> $instance_elem->{virtualizationType},
					hypervisor				=> $instance_elem->{hypervisor},
				);

				if ($product_codes) {
					$running_instance->product_codes($product_codes);
				}
				
				push @$running_instances, $running_instance;
			}
						
			my $reservation = Net::Amazon::EC2::ReservationInfo->new(
				reservation_id	=> $reservation_set->{reservationId},
				owner_id		=> $reservation_set->{ownerId},
				group_set		=> $group_sets,
				instances_set	=> $running_instances,
				requester_id	=> $reservation_set->{requesterId},
			);
			
			push @$reservations, $reservation;
		}
			
	}

	return $reservations;
}

=head2 describe_instance_attribute(%params)

Returns information about an attribute of an instance. Only one attribute can be specified per call.

=over

=item InstanceId (required)

The instance id we want to describe the attributes of.

=item Attribute (required)

The attribute we want to describe. Valid values are:

=over

=item * instanceType

=item * kernel

=item * ramdisk

=item * userData

=item * disableApiTermination

=item * instanceInitiatedShutdownBehavior

=item * rootDeviceName

=item * blockDeviceMapping

=back 

=back

Returns a Net::Amazon::EC2::DescribeInstanceAttributeResponse object

=cut

sub describe_instance_attribute {
	my $self = shift;
	my %args = validate( @_, {
		InstanceId	=> { type => SCALAR },
		Attribute	=> { type => SCALAR },
	});
	
	my $xml = $self->_sign(Action  => 'DescribeInstanceAttribute', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $attribute_response;
		
		# Test to see which type of attribute we are looking for, to dictacte 
		# how to create the Net::Amazon::EC2::DescribeInstanceAttributeResponse object.
		if ( $args{Attribute} eq 'instanceType' ) {
			$attribute_response = Net::Amazon::EC2::DescribeInstanceAttributeResponse->new(
				instance_id		=> $xml->{instanceId},
				instance_type	=> $xml->{instanceType}{value},
			);
		}
		elsif ( $args{Attribute} eq 'kernel' ) {
			$attribute_response = Net::Amazon::EC2::DescribeInstanceAttributeResponse->new(
				instance_id	=> $xml->{instanceId},
				kernel		=> $xml->{kernel}{value},
			);
		}
		elsif ( $args{Attribute} eq 'ramdisk' ) {
			$attribute_response = Net::Amazon::EC2::DescribeInstanceAttributeResponse->new(
				instance_id	=> $xml->{instanceId},
				ramdisk		=> $xml->{ramdisk}{value},
			);
		}
		elsif ( $args{Attribute} eq 'userData' ) {
			$attribute_response = Net::Amazon::EC2::DescribeInstanceAttributeResponse->new(
				instance_id	=> $xml->{instanceId},
				user_data	=> $xml->{userData}{value},
			);
		}
		elsif ( $args{Attribute} eq 'disableApiTermination' ) {
			$attribute_response = Net::Amazon::EC2::DescribeInstanceAttributeResponse->new(
				instance_id				=> $xml->{instanceId},
				disable_api_termination	=> $xml->{disableApiTermination}{value},
			);
		}
		elsif ( $args{Attribute} eq 'instanceInitiatedShutdownBehavior' ) {
			$attribute_response = Net::Amazon::EC2::DescribeInstanceAttributeResponse->new(
				instance_id								=> $xml->{instanceId},
				instance_initiated_shutdown_behavior	=> $xml->{instanceInitiatedShutdownBehavior}{value},
			);
		}
		elsif ( $args{Attribute} eq 'rootDeviceName' ) {
			$attribute_response = Net::Amazon::EC2::DescribeInstanceAttributeResponse->new(
				instance_id			=> $xml->{instanceId},
				root_device_name	=> $xml->{rootDeviceName}{value},
			);
		}
		elsif ( $args{Attribute} eq 'blockDeviceMapping' ) {
			my $block_mappings;
			foreach my $block_item (@{$xml->{blockDeviceMapping}{item}}) {
				my $ebs_mapping				= Net::Amazon::EC2::EbsInstanceBlockDeviceMapping->new(
					attach_time				=> $block_item->{ebs}{attachTime},
					delete_on_termination	=> $block_item->{ebs}{deleteOnTermination},
					status					=> $block_item->{ebs}{status},
					volume_id				=> $block_item->{ebs}{volumeId},
				);
				my $block_device_mapping	= Net::Amazon::EC2::BlockDeviceMapping->new(
					device_name	=> $block_item->{deviceName},
					ebs			=> $ebs_mapping,
				);
				
				push @$block_mappings, $block_device_mapping;
			}

			warn Dumper($block_mappings);
			$attribute_response = Net::Amazon::EC2::DescribeInstanceAttributeResponse->new(
				instance_id				=> $xml->{instanceId},
				block_device_mapping	=> $block_mappings,
			);
		}
		
		return $attribute_response;
	}
}


=head2 describe_key_pairs(%params)

This method describes the keypairs available on this account. It takes the following parameter:

=over

=item KeyName (optional)

The name of the key to be described. Can be either a scalar or an array ref.

=back

Returns an array ref of Net::Amazon::EC2::DescribeKeyPairsResponse objects

=cut

sub describe_key_pairs {
	my $self = shift;
	my %args = validate( @_, {
		KeyName => { type => SCALAR | ARRAYREF, optional => 1 },
	});
	
	# If we have a array ref of instances lets split them out into their InstanceId.n format
	if (ref ($args{KeyName}) eq 'ARRAY') {
		my $keynames	= delete $args{KeyName};
		my $count		= 1;
		foreach my $keyname (@{$keynames}) {
			$args{"KeyName." . $count} = $keyname;
			$count++;
		}
	}
	
	my $xml = $self->_sign(Action  => 'DescribeKeyPairs', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {	
		my $key_pairs;

		foreach my $pair (@{$xml->{keySet}{item}}) {
			my $key_pair = Net::Amazon::EC2::DescribeKeyPairsResponse->new(
				key_name		=> $pair->{keyName},
				key_fingerprint	=> $pair->{keyFingerprint},
			);
			
			push @$key_pairs, $key_pair;
		}

		return $key_pairs;
	}
}

=head2 describe_regions(%params)

Describes EC2 regions that are currently available to launch instances in for this account.

=over

=item RegionName (optional)

The name of the region(s) to be described. Can be either a scalar or an array ref.

=back

Returns an array ref of Net::Amazon::EC2::Region objects

=cut

sub describe_regions {
	my $self = shift;
	my %args = validate( @_, {
		RegionName	=> { type => ARRAYREF | SCALAR, optional => 1 },
	});

	# If we have a array ref of regions lets split them out into their RegionName.n format
	if (ref ($args{RegionName}) eq 'ARRAY') {
		my $regions			= delete $args{RegionName};
		my $count			= 1;
		foreach my $region (@{$regions}) {
			$args{"RegionName." . $count} = $region;
			$count++;
		}
	}
	
	my $xml = $self->_sign(Action  => 'DescribeRegions', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
 		my $regions;

 		foreach my $region_item (@{$xml->{regionInfo}{item}}) {
 			my $region = Net::Amazon::EC2::Region->new(
 				region_name			=> $region_item->{regionName},
 				region_endpoint		=> $region_item->{regionEndpoint},
 			);
 			
 			push @$regions, $region;
 		}
 		
 		return $regions;
	}
}

=head2 describe_reserved_instances(%params)

Describes Reserved Instances that you purchased.

=over

=item ReservedInstancesId (optional)

The reserved instance id(s) to be described. Can be either a scalar or an array ref.

=back

Returns an array ref of Net::Amazon::EC2::ReservedInstance objects

=cut

sub describe_reserved_instances {
	my $self = shift;
	my %args = validate( @_, {
		ReservedInstancesId	=> { type => ARRAYREF | SCALAR, optional => 1 },
	});

	# If we have a array ref of reserved instances lets split them out into their ReservedInstancesId.n format
	if (ref ($args{ReservedInstancesId}) eq 'ARRAY') {
		my $reserved_instance_ids	= delete $args{ReservedInstancesId};
		my $count					= 1;
		foreach my $reserved_instance_id (@{$reserved_instance_ids}) {
			$args{"ReservedInstancesId." . $count} = $reserved_instance_id;
			$count++;
		}
	}
	
	my $xml = $self->_sign(Action  => 'DescribeReservedInstances', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
 		my $reserved_instances;

 		foreach my $reserved_instance_item (@{$xml->{reservedInstancesSet}{item}}) {
 			my $reserved_instance = Net::Amazon::EC2::ReservedInstance->new(
				reserved_instances_id	=> $reserved_instance_item->{reservedInstancesId},
				instance_type			=> $reserved_instance_item->{instanceType},
				availability_zone		=> $reserved_instance_item->{availabilityZone},
				duration				=> $reserved_instance_item->{duration},
				start					=> $reserved_instance_item->{start},
				usage_price				=> $reserved_instance_item->{usagePrice},
				fixed_price				=> $reserved_instance_item->{fixedPrice},
				instance_count			=> $reserved_instance_item->{instanceCount},
				product_description		=> $reserved_instance_item->{productDescription},
				state					=> $reserved_instance_item->{state},
 			);
 			
 			push @$reserved_instances, $reserved_instance;
 		}
 		
 		return $reserved_instances;
	}
}

=head2 describe_reserved_instances_offerings(%params)

Describes Reserved Instance offerings that are available for purchase. With Amazon EC2 Reserved Instances, 
you purchase the right to launch Amazon EC2 instances for a period of time (without getting insufficient 
capacity errors) and pay a lower usage rate for the actual time used.

=over

=item ReservedInstancesOfferingId (optional)

ID of the Reserved Instances to describe.

=item InstanceType (optional)

The instance type on which the Reserved Instance can be used.

=item AvailabilityZone (optional)

The Availability Zone in which the Reserved Instance can be used.

=item ProductDescription (optional)

The Reserved Instance description.

=back

Returns an array ref of Net::Amazon::EC2::ReservedInstanceOffering objects

=cut

sub describe_reserved_instances_offerings {
	my $self = shift;
	my %args = validate( @_, {
		ReservedInstancesOfferingId	=> { type => SCALAR, optional => 1 },
		InstanceType				=> { type => SCALAR, optional => 1 },
		AvailabilityZone			=> { type => SCALAR, optional => 1 },
		ProductDescription			=> { type => SCALAR, optional => 1 },
	});

	my $xml = $self->_sign(Action  => 'DescribeReservedInstancesOfferings', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
 		my $reserved_instance_offerings;

 		foreach my $reserved_instance_offering_item (@{$xml->{reservedInstancesOfferingsSet}{item}}) {
 			my $reserved_instance_offering = Net::Amazon::EC2::ReservedInstanceOffering->new(
				reserved_instances_offering_id	=> $reserved_instance_offering_item->{reservedInstancesOfferingId},
				instance_type					=> $reserved_instance_offering_item->{instanceType},
				availability_zone				=> $reserved_instance_offering_item->{availabilityZone},
				duration						=> $reserved_instance_offering_item->{duration},
				start							=> $reserved_instance_offering_item->{start},
				usage_price						=> $reserved_instance_offering_item->{usagePrice},
				fixed_price						=> $reserved_instance_offering_item->{fixedPrice},
				instance_count					=> $reserved_instance_offering_item->{instanceCount},
				product_description				=> $reserved_instance_offering_item->{productDescription},
				state							=> $reserved_instance_offering_item->{state},
 			);
 			
 			push @$reserved_instance_offerings, $reserved_instance_offering;
 		}
 		
 		return $reserved_instance_offerings;
	}
}

=head2 describe_security_groups(%params)

This method describes the security groups available to this account. It takes the following parameter:

=over

=item GroupName (optional)

The name of the security group(s) to be described. Can be either a scalar or an array ref.

=back

Returns an array ref of Net::Amazon::EC2::SecurityGroup objects

=cut

sub describe_security_groups {
	my $self = shift;
	my %args = validate( @_, {
		GroupName => { type => SCALAR | ARRAYREF, optional => 1 },
	});

	# If we have a array ref of instances lets split them out into their InstanceId.n format
	if (ref ($args{GroupName}) eq 'ARRAY') {
		my $groups = delete $args{GroupName};
		my $count = 1;
		foreach my $group (@{$groups}) {
			$args{"GroupName." . $count} = $group;
			$count++;
		}
	}
	
	my $xml = $self->_sign(Action  => 'DescribeSecurityGroups', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $security_groups;
		foreach my $sec_grp (@{$xml->{securityGroupInfo}{item}}) {
			my $owner_id = $sec_grp->{ownerId};
			my $group_name = $sec_grp->{groupName};
			my $group_description = $sec_grp->{groupDescription};
			my $ip_permissions;

			foreach my $ip_perm (@{$sec_grp->{ipPermissions}{item}}) {
				my $ip_protocol = $ip_perm->{ipProtocol};
				my $from_port	= $ip_perm->{fromPort};
				my $to_port		= $ip_perm->{toPort};
				my $icmp_port	= $ip_perm->{icmpPort};
				my $groups;
				my $ip_ranges;
				
				if (grep { defined && length } $ip_perm->{groups}{item}) {
					foreach my $grp (@{$ip_perm->{groups}{item}}) {
						my $group = Net::Amazon::EC2::UserIdGroupPair->new(
							user_id		=> $grp->{userId},
							group_name	=> $grp->{groupName},
						);
						
						push @$groups, $group;
					}
				}
				
				if (grep { defined && length } $ip_perm->{ipRanges}{item}) {
					foreach my $rng (@{$ip_perm->{ipRanges}{item}}) {
						my $ip_range = Net::Amazon::EC2::IpRange->new(
							cidr_ip => $rng->{cidrIp},
						);
						
						push @$ip_ranges, $ip_range;
					}
				}

								
				my $ip_permission = Net::Amazon::EC2::IpPermission->new(
					ip_protocol			=> $ip_protocol,
					group_name			=> $group_name,
					group_description	=> $group_description,
					from_port			=> $from_port,
					to_port				=> $to_port,
					icmp_port			=> $icmp_port,
				);
				
				if ($ip_ranges) {
					$ip_permission->ip_ranges($ip_ranges);
				}

				if ($groups) {
					$ip_permission->groups($groups);
				}
				
				push @$ip_permissions, $ip_permission;
			}
			
			my $security_group = Net::Amazon::EC2::SecurityGroup->new(
				owner_id			=> $owner_id,
				group_name			=> $group_name,
				group_description	=> $group_description,
				ip_permissions		=> $ip_permissions,
			);
			
			push @$security_groups, $security_group;
		}
		
		return $security_groups;	
	}
}

=head2 describe_snapshot_attribute(%params)

Describes the snapshots attributes related to the snapshot in question. It takes the following arguments:

=over

=item SnapshotId (optional)

Either a scalar or array ref of snapshot id's can be passed in. If this isn't passed in
it will describe the attributes of all the current snapshots.

=item Attribute (required)

The attribute to describe, currently, the only valid attribute is createVolumePermission.

=back

Returns a Net::Amazon::EC2::SnapshotAttribute object.

=cut

sub describe_snapshot_attribute {
	my $self = shift;
	my %args = validate( @_, {
		SnapshotId		=> { type => ARRAYREF | SCALAR, optional => 1 },
		Attribute		=> { type => SCALAR },
	});

	# If we have a array ref of volumes lets split them out into their SnapshotId.n format
	if (ref ($args{SnapshotId}) eq 'ARRAY') {
		my $snapshots		= delete $args{SnapshotId};
		my $count			= 1;
		foreach my $snapshot (@{$snapshots}) {
			$args{"SnapshotId." . $count} = $snapshot;
			$count++;
		}
	}
	
	my $xml = $self->_sign(Action  => 'DescribeSnapshotAttribute', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $perms;
		
		unless ( grep { defined && length } $xml->{createVolumePermission} and ref $xml->{createVolumePermission} ne 'HASH') {
			$perms = undef;
		}

 		foreach my $perm_item (@{$xml->{createVolumePermission}{item}}) {
 			my $perm = Net::Amazon::EC2::CreateVolumePermission->new(
 				user_id			=> $perm_item->{userId},
 				group			=> $perm_item->{group},
 			);
 			
 			push @$perms, $perm;
 		}

		my $snapshot_attribute = Net::Amazon::EC2::SnapshotAttribute->new(
			snapshot_id		=> $xml->{snapshotId},
			permissions		=> $perms,
		);
 		
 		return $snapshot_attribute;
	}
}


=head2 describe_snapshots(%params)

Describes the snapshots available to the user. It takes the following arguments:

=over

=item SnapshotId (optional)

Either a scalar or array ref of snapshot id's can be passed in. If this isn't passed in
it will describe all the current snapshots.

=item Owner (optional)

The owner of the snapshot.

=item RestorableBy (optional)

A user who can create volumes from the snapshot.

=back

Returns an array ref of Net::Amazon::EC2::Snapshot objects.

=cut

sub describe_snapshots {
	my $self = shift;
	my %args = validate( @_, {
		SnapshotId		=> { type => ARRAYREF | SCALAR, optional => 1 },
		Owner			=> { type => SCALAR, optional => 1 },
		RestorableBy	=> { type => SCALAR, optional => 1 },
	});

	# If we have a array ref of volumes lets split them out into their SnapshotId.n format
	if (ref ($args{SnapshotId}) eq 'ARRAY') {
		my $snapshots		= delete $args{SnapshotId};
		my $count			= 1;
		foreach my $snapshot (@{$snapshots}) {
			$args{"SnapshotId." . $count} = $snapshot;
			$count++;
		}
	}
	
	my $xml = $self->_sign(Action  => 'DescribeSnapshots', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
 		my $snapshots;

 		foreach my $snap (@{$xml->{snapshotSet}{item}}) {
			unless ( grep { defined && length } $snap->{description} and ref $snap->{description} ne 'HASH') {
				$snap->{description} = undef;
			}

			unless ( grep { defined && length } $snap->{progress} and ref $snap->{progress} ne 'HASH') {
				$snap->{progress} = undef;
			}

 			my $snapshot = Net::Amazon::EC2::Snapshot->new(
 				snapshot_id		=> $snap->{snapshotId},
 				status			=> $snap->{status},
 				volume_id		=> $snap->{volumeId},
 				start_time		=> $snap->{startTime},
 				progress		=> $snap->{progress},
 				owner_id		=> $snap->{ownerId},
 				volume_size		=> $snap->{volumeSize},
 				description		=> $snap->{description},
 				owner_alias		=> $snap->{ownerAlias},
 			);
 			
 			push @$snapshots, $snapshot;
 		}
 		
 		return $snapshots;
	}
}

=head2 describe_volumes(%params)

Describes the volumes currently created. It takes the following arguments:

=over

=item VolumeId (optional)

Either a scalar or array ref of volume id's can be passed in. If this isn't passed in
it will describe all the current volumes.

=back

Returns an array ref of Net::Amazon::EC2::Volume objects.

=cut

sub describe_volumes {
	my $self = shift;
	my %args = validate( @_, {
		VolumeId	=> { type => ARRAYREF | SCALAR, optional => 1 },
	});

	# If we have a array ref of volumes lets split them out into their Volume.n format
	if (ref ($args{VolumeId}) eq 'ARRAY') {
		my $volumes		= delete $args{VolumeId};
		my $count			= 1;
		foreach my $volume (@{$volumes}) {
			$args{"VolumeId." . $count} = $volume;
			$count++;
		}
	}
	
	my $xml = $self->_sign(Action  => 'DescribeVolumes', %args);

	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $volumes;

		foreach my $volume_set (@{$xml->{volumeSet}{item}}) {
			my $attachments;
			unless ( grep { defined && length } $volume_set->{snapshotId} and ref $volume_set->{snapshotId} ne 'HASH') {
				$volume_set->{snapshotId} = undef;
			}
		
			foreach my $attachment_set (@{$volume_set->{attachmentSet}{item}}) {
 				my $attachment = Net::Amazon::EC2::Attachment->new(
 					volume_id				=> $attachment_set->{volumeId},
 					status					=> $attachment_set->{status},
 					instance_id				=> $attachment_set->{instanceId},
 					attach_time				=> $attachment_set->{attachTime},
 					device					=> $attachment_set->{device},
 					delete_on_termination	=> $attachment_set->{deleteOnTermination},
 				);
 				
 				push @$attachments, $attachment;
			}
			
			my $volume = Net::Amazon::EC2::Volume->new(
				volume_id		=> $volume_set->{volumeId},
				status			=> $volume_set->{status},
				zone			=> $volume_set->{availabilityZone},
				create_time		=> $volume_set->{createTime},
				snapshot_id		=> $volume_set->{snapshotId},
				size			=> $volume_set->{size},
				attachments		=> $attachments,
			);
			
			push @$volumes, $volume;
		}
		
		return $volumes;
	}
}

=head2 describe_tags(%params)

This method describes the tags available on this account. It takes the following parameter:

=over

=item Filter.Name (optional)

The name of the Filter.Name to be described. Can be either a scalar or an array ref.

=item Filter.Value (optional)

The name of the Filter.Value to be described. Can be either a scalar or an array ref.

=back

Returns an array ref of Net::Amazon::EC2::DescribeTags objects

=cut

sub describe_tags {
	my $self = shift;
	my %args = validate( @_, {
		'Filter.Name'				=> { type => ARRAYREF | SCALAR },
		'Filter.Value'				=> { type => ARRAYREF | SCALAR },
	});

	if (ref ($args{'Filter.Name'}) eq 'ARRAY') {
		my $keys			= delete $args{'Filter.Name'};
		my $count			= 1;
		foreach my $key (@{$keys}) {
			$args{"Filter." . $count . ".Name"} = $key;
			$count++;
		}
	}
	if (ref ($args{'Filter.Value'}) eq 'ARRAY') {
		my $keys			= delete $args{'Filter.Value'};
		my $count			= 1;
		foreach my $key (@{$keys}) {
			$args{"Filter." . $count . ".Value"} = $key;
			$count++;
		}
	}

	my $xml = $self->_sign(Action  => 'DescribeTags', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {	
		my $tags;

		foreach my $pair (@{$xml->{tagSet}{item}}) {
			my $tag = Net::Amazon::EC2::DescribeTags->new(
				resource_id		=> $pair->{resourceId},
				resource_type	=> $pair->{resourceType},
				key				=> $pair->{key},
				value			=> $pair->{value},
			);
			
			push @$tags, $tag;
		}

		return $tags;
	}
}

=head2 detach_volume(%params)

Detach a volume from an instance.

=over

=item VolumeId (required)

The volume id you wish to detach.

=item InstanceId (optional)

The instance id you wish to detach from.

=item Device (optional)

The device the volume was attached as.

=item Force (optional)

A boolean for if to forcibly detach the volume from the instance.
WARNING: This can lead to data loss or a corrupted file system.
	   Use this option only as a last resort to detach a volume
	   from a failed instance.  The instance will not have an
	   opportunity to flush file system caches nor file system
	   meta data.

=back

Returns a Net::Amazon::EC2::Attachment object containing the resulting volume status.

=cut

sub detach_volume {
	my $self = shift;
	my %args = validate( @_, {
		VolumeId	=> { type => SCALAR },
		InstanceId	=> { type => SCALAR, optional => 1 },
		Device		=> { type => SCALAR, optional => 1 },
		Force		=> { type => SCALAR, optional => 1 },
	});

	my $xml = $self->_sign(Action  => 'DetachVolume', %args);

	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $attachment = Net::Amazon::EC2::Attachment->new(
			volume_id	=> $xml->{volumeId},
			status		=> $xml->{status},
			instance_id	=> $xml->{instanceId},
			attach_time	=> $xml->{attachTime},
			device		=> $xml->{device},
		);
		
		return $attachment;
	}
}

=head2 disassociate_address(%params)

Disassociates an elastic IP address with an instance. It takes the following arguments:

=over

=item PublicIp (required)

The IP address to disassociate

=back

Returns true if the disassociation succeeded.

=cut

sub disassociate_address {
	my $self = shift;
	my %args = validate( @_, {
		PublicIp 		=> { type => SCALAR },
	});
	
	my $xml = $self->_sign(Action  => 'DisassociateAddress', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}
}

=head2 get_console_output(%params)

This method gets the output from the virtual console for an instance.  It takes the following parameters:

=over

=item InstanceId (required)

A scalar containing a instance id.

=back

Returns a Net::Amazon::EC2::ConsoleOutput object.

=cut

sub get_console_output {
	my $self = shift;
	my %args = validate( @_, {
		InstanceId	=> { type => SCALAR },
	});
	
	
	my $xml = $self->_sign(Action  => 'GetConsoleOutput', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $console_output = Net::Amazon::EC2::ConsoleOutput->new(
			instance_id	=> $xml->{instanceId},
			timestamp	=> $xml->{timestamp},
			output		=> decode_base64($xml->{output}),
		);
		
		return $console_output;
	}
}

=head2 get_password_data(%params)

Retrieves the encrypted administrator password for the instances running Windows. This procedure is not applicable for Linux and UNIX instances.

=over

=item InstanceId (required)

The Instance Id for which to retrieve the password.

=back

Returns a Net::Amazon::EC2::InstancePassword object

=cut

sub get_password_data {
	my $self = shift;
	my %args = validate( @_, {
		instanceId	=> { type => SCALAR },
	});

	my $xml = $self->_sign(Action  => 'GetPasswordData', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $instance_password = Net::Amazon::EC2::InstancePassword->new(
			instance_id		=> $xml->{instanceId},
			timestamp		=> $xml->{timestamp},
			password_data	=> $xml->{passwordData},
		);
 			
 		return $instance_password;
	}
}

=head2 modify_image_attribute(%params)

This method modifies attributes of an machine image.

=over

=item ImageId (required)

The AMI to modify the attributes of.

=item Attribute (required)

The attribute you wish to modify, right now the attributes you can modify are launchPermission and productCodes

=item OperationType (required for launchPermission)

The operation you wish to perform on the attribute. Right now just 'add' and 'remove' are supported.

=item UserId (required for launchPermission)

User Id's you wish to add/remove from the attribute.

=item UserGroup (required for launchPermission)

Groups you wish to add/remove from the attribute.  Currently there is only one User Group available 'all' for all Amazon EC2 customers.

=item ProductCode (required for productCodes)

Attaches a product code to the AMI. Currently only one product code can be assigned to the AMI.  Once this is set it cannot be changed or reset.

=back

Returns 1 if the modification succeeds.

=cut

sub modify_image_attribute {
	my $self = shift;
	my %args = validate( @_, {
		ImageId			=> { type => SCALAR },
		Attribute 		=> { type => SCALAR },
		OperationType	=> { type => SCALAR, optional => 1 },
		UserId 			=> { type => SCALAR | ARRAYREF, optional => 1 },
		UserGroup 		=> { type => SCALAR | ARRAYREF, optional => 1 },
		ProductCode		=> { type => SCALAR, optional => 1 },
	});
	
	
	my $xml = $self->_sign(Action  => 'ModifyImageAttribute', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}
}

=head2 modify_instance_attribute(%params)

Modify an attribute of an instance. Only one attribute can be specified per call.

=over

=item InstanceId (required)

The instance id we want to modify the attributes of.

=item Attribute (required)

The attribute we want to modify. Valid values are:

=over

=item * instanceType

=item * kernel

=item * ramdisk

=item * userData

=item * disableApiTermination

=item * instanceInitiatedShutdownBehavior

=item * rootDeviceName

=item * blockDeviceMapping

=back 

=item Value (required)

The value to set the attribute to.

=back

Returns 1 if the modification succeeds.

=cut

sub modify_instance_attribute {
	my $self = shift;
	my %args = validate( @_, {
		InstanceId	=> { type => SCALAR },
		Attribute	=> { type => SCALAR },
		Value		=> { type => SCALAR },
	});
	
	my $xml = $self->_sign(Action  => 'ModifyInstanceAttribute', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}
}


=head2 modify_snapshot_attribute(%params)

This method modifies attributes of a snapshot.

=over

=item SnapshotId (required)

The snapshot id to modify the attributes of.

=item UserId (optional)

User Id you wish to add/remove create volume permissions for.

=item UserGroup (optional)

User Id you wish to add/remove create volume permissions for. To make the snapshot createable by all
set the UserGroup to "all".

=item Attribute (required)

The attribute you wish to modify, right now the only attribute you can modify is "CreateVolumePermission" 

=item OperationType (required)

The operation you wish to perform on the attribute. Right now just 'add' and 'remove' are supported.

=back

Returns 1 if the modification succeeds.

=cut

sub modify_snapshot_attribute {
	my $self = shift;
	my %args = validate( @_, {
		SnapshotId		=> { type => SCALAR },
		UserId			=> { type => SCALAR, optional => 1 },
		UserGroup		=> { type => SCALAR, optional => 1 },
		Attribute		=> { type => SCALAR },
		OperationType	=> { type => SCALAR },
	});
	
	
	my $xml = $self->_sign(Action  => 'ModifySnapshotAttribute', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}
}

=head2 monitor_instances(%params)

Enables monitoring for a running instance. For more information, refer to the Amazon CloudWatch Developer Guide.

=over

=item InstanceId (required)

The instance id(s) to monitor. Can be a scalar or an array ref

=back

Returns an array ref of Net::Amazon::EC2::MonitoredInstance objects

=cut

sub monitor_instances {
	my $self = shift;
	my %args = validate( @_, {
		InstanceId	=> { type => ARRAYREF | SCALAR, optional => 1 },
	});

	# If we have a array ref of instances lets split them out into their InstanceId.n format
	if (ref ($args{InstanceId}) eq 'ARRAY') {
		my $instance_ids	= delete $args{InstanceId};
		my $count					= 1;
		foreach my $instance_id (@{$instance_ids}) {
			$args{"InstanceId." . $count} = $instance_id;
			$count++;
		}
	}
	
	my $xml = $self->_sign(Action  => 'MonitorInstances', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
 		my $monitored_instances;

 		foreach my $monitored_instance_item (@{$xml->{instancesSet}{item}}) {
 			my $monitored_instance = Net::Amazon::EC2::ReservedInstance->new(
				instance_id	=> $monitored_instance_item->{instanceId},
				state		=> $monitored_instance_item->{monitoring}{state},
 			);
 			
 			push @$monitored_instances, $monitored_instance;
 		}
 		
 		return $monitored_instances;
	}
}

=head2 purchase_reserved_instances_offering(%params)

Purchases a Reserved Instance for use with your account. With Amazon EC2 Reserved Instances, you purchase the right to 
launch Amazon EC2 instances for a period of time (without getting insufficient capacity errors) and pay a lower usage 
rate for the actual time used.

=over

=item ReservedInstancesOfferingId (required)

ID of the Reserved Instances to describe. Can be either a scalar or an array ref.

=item InstanceCount (optional)

The number of Reserved Instances to purchase (default is 1). Can be either a scalar or an array ref.

NOTE NOTE NOTE, the array ref needs to line up with the InstanceCount if you want to pass that in, so that 
the right number of instances are started of the right instance offering

=back

Returns 1 if the reservations succeeded.

=cut

sub purchase_reserved_instances_offering {
	my $self = shift;
	my %args = validate( @_, {
		ReservedInstancesOfferingId	=> { type => ARRAYREF | SCALAR },
		InstanceCount				=> { type => ARRAYREF | SCALAR, optional => 1 },
	});
	
	# If we have a array ref of reserved instance offerings lets split them out into their ReservedInstancesOfferingId.n format
	if (ref ($args{ReservedInstancesOfferingId}) eq 'ARRAY') {
		my $reserved_instance_offering_ids = delete $args{ReservedInstancesOfferingId};
		my $count = 1;
		foreach my $reserved_instance_offering_id (@{$reserved_instance_offering_ids}) {
			$args{"ReservedInstancesOfferingId." . $count} = $reserved_instance_offering_id;
			$count++;
		}
	}

	# If we have a array ref of instance counts lets split them out into their InstanceCount.n format
	if (ref ($args{InstanceCount}) eq 'ARRAY') {
		my $instance_counts = delete $args{InstanceCount};
		my $count = 1;
		foreach my $instance_count (@{$instance_counts}) {
			$args{"InstanceCount." . $count} = $instance_count;
			$count++;
		}
	}
	
	my $xml = $self->_sign(Action  => 'PurchaseReservedInstancesOffering', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{reservedInstancesId} ) {
			return 1;
		}
		else {
			return undef;
		}
	}
}

=head2 reboot_instances(%params)

This method reboots an instance.  It takes the following parameters:

=over

=item InstanceId (required)

Instance Id of the instance you wish to reboot. Can be either a scalar or array ref of instances to reboot.

=back

Returns 1 if the reboot succeeded.

=cut

sub reboot_instances {
	my $self = shift;
	my %args = validate( @_, {
		InstanceId	=> { type => SCALAR },
	});
	
	# If we have a array ref of instances lets split them out into their InstanceId.n format
	if (ref ($args{InstanceId}) eq 'ARRAY') {
		my $instance_ids = delete $args{InstanceId};
		my $count = 1;
		foreach my $instance_id (@{$instance_ids}) {
			$args{"InstanceId." . $count} = $instance_id;
			$count++;
		}
	}
	
	my $xml = $self->_sign(Action  => 'RebootInstances', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}
}

=head2 register_image(%params)

This method registers an AMI on the EC2. It takes the following parameter:

=over

=item imageLocation (optional)

The location of the AMI manifest on S3

=item name (required)

The name of the AMI that was provided during image creation.

=item description (optional)

The description of the AMI.

=item architecture (optional)

The architecture of the image. Either i386 or x86_64

=item kernelId (optional)

The ID of the kernel to select. 

=item ramdiskId (optional)

The ID of the RAM disk to select. Some kernels require additional drivers at launch. 

=item rootDeviceName (optional)

The root device name (e.g., /dev/sda1).

=item blockDeviceMapping (optional)

This needs to be a data structure like this:

[
	{
		deviceName	=> "/dev/sdh", (optional)
		virtualName	=> "ephermel0", (optional)
		noDevice	=> "/dev/sdl", (optional),
		ebs			=> {
			snapshotId			=> "snap-0000", (optional)
			volumeSize			=> "20", (optional)
			deleteOnTermination	=> "false", (optional)
		},
	},
	...
]	

=back

Returns the image id of the new image on EC2.

=cut

sub register_image {
	my $self = shift;
	my %args = validate( @_, {
		ImageLocation		=> { type => SCALAR, optional => 1 },
		Name				=> { type => SCALAR },
		Description			=> { type => SCALAR, optional => 1 },
		Architecture		=> { type => SCALAR, optional => 1 },
		KernelId			=> { type => SCALAR, optional => 1 },
		RamdiskId			=> { type => SCALAR, optional => 1 },
		RootDeviceName		=> { type => SCALAR, optional => 1 },
		BlockDeviceMapping	=> { type => ARRAYREF, optional => 1 },
	});

	
	# If we have a array ref of block devices, we need to split them up
	if (ref ($args{BlockDeviceMapping}) eq 'ARRAY') {
		my $block_devices = delete $args{BlockDeviceMapping};
		my $count = 1;
		foreach my $block_device (@{$block_devices}) {
			$args{"BlockDeviceMapping." . $count . ".DeviceName"}				= $block_device->{deviceName} if $block_device->{deviceName};
			$args{"BlockDeviceMapping." . $count . ".VirtualName"}				= $block_device->{virtualName} if $block_device->{virtualName};
			$args{"BlockDeviceMapping." . $count . ".NoDevice"}					= $block_device->{noDevice} if $block_device->{noDevice};
			$args{"BlockDeviceMapping." . $count . ".Ebs.SnapshotId"}			= $block_device->{ebs}{snapshotId} if $block_device->{ebs}{snapshotId};
			$args{"BlockDeviceMapping." . $count . ".Ebs.VolumeSize"}			= $block_device->{ebs}{volumeSize} if $block_device->{ebs}{volumeSize};
			$args{"BlockDeviceMapping." . $count . ".Ebs.DeleteOnTermination"}	= $block_device->{ebs}{deleteOnTermination} if $block_device->{ebs}{deleteOnTermination};
			$count++;
		}
	}

	my $xml	= $self->_sign(Action  => 'RegisterImage', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		return $xml->{imageId};
	}
}

=head2 release_address(%params)

Releases an allocated IP address. It takes the following arguments:

=over

=item PublicIp (required)

The IP address to release

=back

Returns true if the releasing succeeded.

=cut

sub release_address {
	my $self = shift;
	my %args = validate( @_, {
		PublicIp 		=> { type => SCALAR },
	});
	
	my $xml = $self->_sign(Action  => 'ReleaseAddress', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}
}

=head2 reset_image_attribute(%params)

This method resets an attribute for an AMI to its default state (NOTE: product codes cannot be reset).  
It takes the following parameters:

=over

=item ImageId (required)

The image id of the AMI you wish to reset the attributes on.

=item Attribute (required)

The attribute you want to reset.

=back

Returns 1 if the attribute reset succeeds.

=cut

sub reset_image_attribute {
	my $self = shift;
	my %args = validate( @_, {
		ImageId			=> { type => SCALAR },
		Attribute 		=> { type => SCALAR },
	});
	
	my $xml = $self->_sign(Action  => 'ResetImageAttribute', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}
}

=head2 reset_instance_attribute(%params)

Reset an attribute of an instance. Only one attribute can be specified per call.

=over

=item InstanceId (required)

The instance id we want to reset the attributes of.

=item Attribute (required)

The attribute we want to reset. Valid values are:

=over

=item * kernel

=item * ramdisk

=back 

=back

Returns 1 if the reset succeeds.

=cut

sub reset_instance_attribute {
	my $self = shift;
	my %args = validate( @_, {
		InstanceId		=> { type => SCALAR },
		Attribute 		=> { type => SCALAR },
	});
	
	my $xml = $self->_sign(Action  => 'ResetInstanceAttribute', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}
}

=head2 reset_snapshot_attribute(%params)

This method resets an attribute for an snapshot to its default state.

It takes the following parameters:

=over

=item SnapshotId (required)

The snapshot id of the snapshot you wish to reset the attributes on.

=item Attribute (required)

The attribute you want to reset (currently "CreateVolumePermission" is the only
valid attribute).

=back

Returns 1 if the attribute reset succeeds.

=cut

sub reset_snapshot_attribute {
	my $self = shift;
	my %args = validate( @_, {
		SnapshotId	=> { type => SCALAR },
		Attribute	=> { type => SCALAR },
	});
	
	my $xml = $self->_sign(Action  => 'ResetSnapshotAttribute', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}
}

=head2 revoke_security_group_ingress(%params)

This method revoke permissions to a security group.  It takes the following parameters:

=over

=item GroupName (required)

The name of the group to revoke security rules from.

=item SourceSecurityGroupName (requred when revoking a user and group together)

Name of the group to revoke access from.

=item SourceSecurityGroupOwnerId (required when revoking a user and group together)

Owner of the group to revoke access from.

=item IpProtocol (required when revoking access from a CIDR)

IP Protocol of the rule you are revoking access from (TCP, UDP, or ICMP)

=item FromPort (required when revoking access from a CIDR)

Beginning of port range to revoke access from.

=item ToPort (required when revoking access from a CIDR)

End of port range to revoke access from.

=item CidrIp (required when revoking access from a CIDR)

The CIDR IP space we are revoking access from.

=back

Revoking a rule can be done in two ways: revoking a source group name + source group owner id, or, by Protocol + start port + end port + CIDR IP.  The two are mutally exclusive.

Returns 1 if rule is revoked successfully.

=cut

sub revoke_security_group_ingress {
	my $self = shift;
	my %args = validate( @_, {
								GroupName					=> { type => SCALAR },
								SourceSecurityGroupName 	=> { 
																	type => SCALAR,
																	depends => ['SourceSecurityGroupOwnerId'],
																	optional => 1 ,
								},
								SourceSecurityGroupOwnerId	=> { type => SCALAR, optional => 1 },
								IpProtocol 					=> { 
																	type => SCALAR,
																	depends => ['FromPort', 'ToPort', 'CidrIp'],
																	optional => 1 
								},
								FromPort 					=> { type => SCALAR, optional => 1 },
								ToPort 						=> { type => SCALAR, optional => 1 },
								CidrIp						=> { type => SCALAR, optional => 1 },
	});
	
	
	my $xml = $self->_sign(Action  => 'RevokeSecurityGroupIngress', %args);

	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		if ($xml->{return} eq 'true') {
			return 1;
		}
		else {
			return undef;
		}
	}
}

=head2 run_instances(%params)

This method will start instance(s) of AMIs on EC2. The parameters indicate which AMI to instantiate and how many / what properties they have:

=over

=item ImageId (required)

The image id you want to start an instance of.

=item MinCount (required)

The minimum number of instances to start.

=item MaxCount (required)

The maximum number of instances to start.

=item KeyName (optional)

The keypair name to associate this instance with.  If omitted, will use your default keypair.

=item SecurityGroup (optional)

An scalar or array ref. Will associate this instance with the group names passed in.  If omitted, will be associated with the default security group.

=item AdditionalInfo (optional)

Specifies additional information to make available to the instance(s).

=item UserData (optional)

Optional data to pass into the instance being started.  Needs to be base64 encoded.

=item InstanceType (optional)

Specifies the type of instance to start.  The options are:

=over

=item m1.small (default)

1 EC2 Compute Unit (1 virtual core with 1 EC2 Compute Unit). 32-bit, 1.7GB RAM, 160GB disk

=item m1.large: Standard Large Instance

4 EC2 Compute Units (2 virtual cores with 2 EC2 Compute Units each). 64-bit, 7.5GB RAM, 850GB disk

=item m1.xlarge: Standard Extra Large Instance

8 EC2 Compute Units (4 virtual cores with 2 EC2 Compute Units each). 64-bit, 15GB RAM, 1690GB disk

=item c1.medium: High-CPU Medium Instance

5 EC2 Compute Units (2 virutal cores with 2.5 EC2 Compute Units each). 32-bit, 1.7GB RAM, 350GB disk

=item c1.xlarge: High-CPU Extra Large Instance

20 EC2 Compute Units (8 virtual cores with 2.5 EC2 Compute Units each). 64-bit, 7GB RAM, 1690GB disk

=item m2.2xlarge

13 EC2 Compute Units (4 virtual cores with 3.25 EC2 Compute Units each). 64-bit, 34.2GB RAM, 850GB disk

=item m2.4xlarge

26 EC2 Compute Units (8 virtual cores with 3.25 EC2 Compute Units each). 64-bit, 68.4GB RAM, 1690GB disk

=back 

=item Placement.AvailabilityZone (optional)

The availability zone you want to run the instance in

=item KernelId (optional)

The id of the kernel you want to launch the instance with

=item RamdiskId (optional)
  
The id of the ramdisk you want to launch the instance with

=item BlockDeviceMapping.VirtualName (optional)

This is the virtual name for a blocked device to be attached, may pass in a scalar or arrayref

=item BlockDeviceMapping.DeviceName (optional)

This is the device name for a block device to be attached, may pass in a scalar or arrayref

=item Encoding (optional)

The encoding.

=item Version (optional)

The version.

=item Monitoring.Enabled (optional)

Enables monitoring for this instance.

=item SubnetId (optional)

Specifies the subnet ID within which to launch the instance(s) for Amazon Virtual Private Cloud.

=back

Returns a Net::Amazon::EC2::ReservationInfo object

=cut 

sub run_instances {
	my $self = shift;
	my %args = validate( @_, {
		ImageId											=> { type => SCALAR },
		MinCount										=> { type => SCALAR },
		MaxCount										=> { type => SCALAR },
		KeyName											=> { type => SCALAR, optional => 1 },
		SecurityGroup									=> { type => SCALAR | ARRAYREF, optional => 1 },
		AdditionalInfo									=> { type => SCALAR, optional => 1 },
		UserData										=> { type => SCALAR, optional => 1 },
		InstanceType									=> { type => SCALAR, optional => 1 },
		'Placement.AvailabilityZone'					=> { type => SCALAR, optional => 1 },
		KernelId										=> { type => SCALAR, optional => 1 },
		RamdiskId										=> { type => SCALAR, optional => 1 },
		'BlockDeviceMapping.VirtualName'				=> { type => SCALAR | ARRAYREF, optional => 1 },
		'BlockDeviceMapping.DeviceName'					=> { type => SCALAR | ARRAYREF, optional => 1 },
		'BlockDeviceMapping.Ebs.SnapshotId'				=> { type => SCALAR | ARRAYREF, optional => 1 },
		'BlockDeviceMapping.Ebs.VolumeSize'				=> { type => SCALAR | ARRAYREF, optional => 1 },
		'BlockDeviceMapping.Ebs.DeleteOnTermination'	=> { type => SCALAR | ARRAYREF, optional => 1 },
		Encoding										=> { type => SCALAR, optional => 1 },
		Version											=> { type => SCALAR, optional => 1 },
		'Monitoring.Enabled'							=> { type => SCALAR, optional => 1 },
		SubnetId										=> { type => SCALAR, optional => 1 },
		DisableApiTermination							=> { type => SCALAR, optional => 1 },
		InstanceInitiatedShutdownBehavior				=> { type => SCALAR, optional => 1 },
	});
	
	# If we have a array ref of instances lets split them out into their SecurityGroup.n format
	if (ref ($args{SecurityGroup}) eq 'ARRAY') {
		my $security_groups	= delete $args{SecurityGroup};
		my $count			= 1;
		foreach my $security_group (@{$security_groups}) {
			$args{"SecurityGroup." . $count} = $security_group;
			$count++;
		}
	}

	# If we have a array ref of block device virtual names lets split them out into their BlockDeviceMapping.n.VirtualName format
	if (ref ($args{'BlockDeviceMapping.VirtualName'}) eq 'ARRAY') {
		my $virtual_names	= delete $args{'BlockDeviceMapping.VirtualName'};
		my $count			= 1;
		foreach my $virtual_name (@{$virtual_names}) {
			$args{"BlockDeviceMapping." . $count . ".VirtualName"} = $virtual_name;
			$count++;
		}
	}

	# If we have a array ref of block device virtual names lets split them out into their BlockDeviceMapping.n.DeviceName format
	if (ref ($args{'BlockDeviceMapping.DeviceName'}) eq 'ARRAY') {
		my $device_names	= delete $args{'BlockDeviceMapping.DeviceName'};
		my $count			= 1;
		foreach my $device_name (@{$device_names}) {
			$args{"BlockDeviceMapping." . $count . ".DeviceName"} = $device_name;
			$count++;
		}
	}

	# If we have a array ref of block device EBS Snapshots lets split them out into their BlockDeviceMapping.n.Ebs.SnapshotId format
	if (ref ($args{'BlockDeviceMapping.Ebs.SnapshotId'}) eq 'ARRAY') {
		my $snapshot_ids	= delete $args{'BlockDeviceMapping.Ebs.SnapshotId'};
		my $count			= 1;
		foreach my $snapshot_id (@{$snapshot_ids}) {
			$args{"BlockDeviceMapping." . $count . ".Ebs.SnapshotId"} = $snapshot_id;
			$count++;
		}
	}

	# If we have a array ref of block device EBS VolumeSizes lets split them out into their BlockDeviceMapping.n.Ebs.VolumeSize format
	if (ref ($args{'BlockDeviceMapping.Ebs.VolumeSize'}) eq 'ARRAY') {
		my $volume_sizes	= delete $args{'BlockDeviceMapping.Ebs.VolumeSize'};
		my $count			= 1;
		foreach my $volume_size (@{$volume_sizes}) {
			$args{"BlockDeviceMapping." . $count . ".Ebs.VolumeSize"} = $volume_size;
			$count++;
		}
	}

	# If we have a array ref of block device EBS DeleteOnTerminations lets split them out into their BlockDeviceMapping.n.Ebs.DeleteOnTermination format
	if (ref ($args{'BlockDeviceMapping.Ebs.DeleteOnTermination'}) eq 'ARRAY') {
		my $terminations	= delete $args{'BlockDeviceMapping.Ebs.DeleteOnTermination'};
		my $count			= 1;
		foreach my $termination (@{$terminations}) {
			$args{"BlockDeviceMapping." . $count . ".Ebs.DeleteOnTermination"} = $termination;
			$count++;
		}
	}

	my $xml = $self->_sign(Action  => 'RunInstances', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $group_sets;
		foreach my $group_arr (@{$xml->{groupSet}{item}}) {
			my $group = Net::Amazon::EC2::GroupSet->new(
				group_id	=> $group_arr->{groupId},
				group_name	=> $group_arr->{groupName},
			);
			push @$group_sets, $group;
		}

		my $running_instances;
		foreach my $instance_elem (@{$xml->{instancesSet}{item}}) {
			my $instance_state_type = Net::Amazon::EC2::InstanceState->new(
				code	=> $instance_elem->{instanceState}{code},
				name	=> $instance_elem->{instanceState}{name},
			);
			
			my $product_codes;
			my $state_reason;
			my $block_device_mappings;
			
			if (grep { defined && length } $instance_elem->{productCodes} ) {
				foreach my $pc (@{$instance_elem->{productCodes}{item}}) {
					my $product_code = Net::Amazon::EC2::ProductCode->new( product_code => $pc->{productCode} );
					push @$product_codes, $product_code;
				}
			}

			unless ( grep { defined && length } $instance_elem->{reason} and ref $instance_elem->{reason} ne 'HASH' ) {
				$instance_elem->{reason} = undef;
			}

			unless ( grep { defined && length } $instance_elem->{privateDnsName} and ref $instance_elem->{privateDnsName} ne 'HASH') {
				$instance_elem->{privateDnsName} = undef;
			}

			unless ( grep { defined && length } $instance_elem->{dnsName} and ref $instance_elem->{dnsName} ne 'HASH') {
				$instance_elem->{dnsName} = undef;
			}

			if ( grep { defined && length } $instance_elem->{stateReason} ) {
				$state_reason = Net::Amazon::EC2::StateReason->new(
					code	=> $instance_elem->{stateReason}{code},
					message	=> $instance_elem->{stateReason}{message},
				);
			}

			if ( grep { defined && length } $instance_elem->{blockDeviceMapping} ) {
				foreach my $bdm ( @{$instance_elem->{blockDeviceMapping}{item}} ) {
					my $ebs_block_device_mapping = Net::Amazon::EC2::EbsInstanceBlockDeviceMapping->new(
						volume_id				=> $bdm->{ebs}{volumeId},
						status					=> $bdm->{ebs}{status},
						attach_time				=> $bdm->{ebs}{attachTime},
						delete_on_termination	=> $bdm->{ebs}{deleteOnTermination},							
					);
					
					my $block_device_mapping = Net::Amazon::EC2::BlockDeviceMapping->new(
						ebs						=> $ebs_block_device_mapping,
						device_name				=> $bdm->{deviceName},
					);
					push @$block_device_mappings, $block_device_mapping;
				}
			}

			my $placement_response = Net::Amazon::EC2::PlacementResponse->new( availability_zone => $instance_elem->{placement}{availabilityZone} );
			
			my $running_instance = Net::Amazon::EC2::RunningInstances->new(
				ami_launch_index		=> $instance_elem->{amiLaunchIndex},
				dns_name				=> $instance_elem->{dnsName},
				image_id				=> $instance_elem->{imageId},
				kernel_id				=> $instance_elem->{kernelId},
				ramdisk_id				=> $instance_elem->{ramdiskId},
				instance_id				=> $instance_elem->{instanceId},
				instance_state			=> $instance_state_type,
				instance_type			=> $instance_elem->{instanceType},
				key_name				=> $instance_elem->{keyName},
				launch_time				=> $instance_elem->{launchTime},
				placement				=> $placement_response,
				private_dns_name		=> $instance_elem->{privateDnsName},
				reason					=> $instance_elem->{reason},
				platform				=> $instance_elem->{platform},
				monitoring				=> $instance_elem->{monitoring}{state},
				subnet_id				=> $instance_elem->{subnetId},
				vpc_id					=> $instance_elem->{vpcId},
				private_ip_address		=> $instance_elem->{privateIpAddress},
				ip_address				=> $instance_elem->{ipAddress},
				architecture			=> $instance_elem->{architecture},
				root_device_name		=> $instance_elem->{rootDeviceName},
				root_device_type		=> $instance_elem->{rootDeviceType},
				block_device_mapping	=> $block_device_mappings,
				state_reason			=> $state_reason,
			);

			if ($product_codes) {
				$running_instance->product_codes($product_codes);
			}
			
			push @$running_instances, $running_instance;
		}
		
		my $reservation = Net::Amazon::EC2::ReservationInfo->new(
			reservation_id	=> $xml->{reservationId},
			owner_id		=> $xml->{ownerId},
			group_set		=> $group_sets,
			instances_set	=> $running_instances,
		);
		
		return $reservation;
	}
}

=head2 start_instances(%params)

Starts an instance that uses an Amazon EBS volume as its root device.

=over

=item InstanceId (required)

Either a scalar or an array ref can be passed in (containing instance ids to be started).

=back

Returns an array ref of Net::Amazon::EC2::InstanceStateChange objects.

=cut

sub start_instances {
	my $self = shift;
	my %args = validate( @_, {
		InstanceId	=> { type => SCALAR | ARRAYREF },
	});
	
	# If we have a array ref of instances lets split them out into their InstanceId.n format
	if (ref ($args{InstanceId}) eq 'ARRAY') {
		my $instance_ids	= delete $args{InstanceId};
		my $count			= 1;
		foreach my $instance_id (@{$instance_ids}) {
			$args{"InstanceId." . $count} = $instance_id;
			$count++;
		}
	}
	
	my $xml = $self->_sign(Action  => 'StartInstances', %args);	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $started_instances;
		
		foreach my $inst (@{$xml->{instancesSet}{item}}) {
			my $previous_state = Net::Amazon::EC2::InstanceState->new(
				code	=> $inst->{previousState}{code},
				name	=> $inst->{previousState}{name},
			);
			
			my $current_state = Net::Amazon::EC2::InstanceState->new(
				code	=> $inst->{currentState}{code},
				name	=> $inst->{currentState}{name},
			);

			my $started_instance = Net::Amazon::EC2::InstanceStateChange->new(
				instance_id		=> $inst->{instanceId},
				previous_state	=> $previous_state,
				current_state	=> $current_state,
			);
			
			push @$started_instances, $started_instance;
		}
		
		return $started_instances;
	}
}

=head2 stop_instances(%params)

Stops an instance that uses an Amazon EBS volume as its root device.

=over

=item InstanceId (required)

Either a scalar or an array ref can be passed in (containing instance ids to be stopped).

=item Force (optional)

If set to true, forces the instance to stop. The instance will not have an opportunity to 
flush file system caches nor file system meta data. If you use this option, you must perform file 
system check and repair procedures. This option is not recommended for Windows instances.

The default is false.

=back

Returns an array ref of Net::Amazon::EC2::InstanceStateChange objects.

=cut

sub stop_instances {
	my $self = shift;
	my %args = validate( @_, {
		InstanceId	=> { type => SCALAR | ARRAYREF },
		Force		=> { type => SCALAR, optional => 1 },
	});
	
	# If we have a array ref of instances lets split them out into their InstanceId.n format
	if (ref ($args{InstanceId}) eq 'ARRAY') {
		my $instance_ids	= delete $args{InstanceId};
		my $count			= 1;
		foreach my $instance_id (@{$instance_ids}) {
			$args{"InstanceId." . $count} = $instance_id;
			$count++;
		}
	}
	
	my $xml = $self->_sign(Action  => 'StopInstances', %args);	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $stopped_instances;
		
		foreach my $inst (@{$xml->{instancesSet}{item}}) {
			my $previous_state = Net::Amazon::EC2::InstanceState->new(
				code	=> $inst->{previousState}{code},
				name	=> $inst->{previousState}{name},
			);
			
			my $current_state = Net::Amazon::EC2::InstanceState->new(
				code	=> $inst->{currentState}{code},
				name	=> $inst->{currentState}{name},
			);

			my $stopped_instance = Net::Amazon::EC2::InstanceStateChange->new(
				instance_id		=> $inst->{instanceId},
				previous_state	=> $previous_state,
				current_state	=> $current_state,
			);
			
			push @$stopped_instances, $stopped_instance;
		}
		
		return $stopped_instances;
	}
}

=head2 terminate_instances(%params)

This method shuts down instance(s) passed into it. It takes the following parameter:

=over

=item InstanceId (required)

Either a scalar or an array ref can be passed in (containing instance ids)

=back

Returns an array ref of Net::Amazon::EC2::InstanceStateChange objects.

=cut

sub terminate_instances {
	my $self = shift;
	my %args = validate( @_, {
		InstanceId => { type => SCALAR | ARRAYREF },
	});
	
	# If we have a array ref of instances lets split them out into their InstanceId.n format
	if (ref ($args{InstanceId}) eq 'ARRAY') {
		my $instance_ids	= delete $args{InstanceId};
		my $count			= 1;
		foreach my $instance_id (@{$instance_ids}) {
			$args{"InstanceId." . $count} = $instance_id;
			$count++;
		}
	}
	
	my $xml = $self->_sign(Action  => 'TerminateInstances', %args);	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
		my $terminated_instances;
		
		foreach my $inst (@{$xml->{instancesSet}{item}}) {
			my $previous_state = Net::Amazon::EC2::InstanceState->new(
				code	=> $inst->{previousState}{code},
				name	=> $inst->{previousState}{name},
			);
			
			my $current_state = Net::Amazon::EC2::InstanceState->new(
				code	=> $inst->{currentState}{code},
				name	=> $inst->{currentState}{name},
			);

			# Note, this is a bit of a backwards incompatible change in so much as I am changing
			# return class for this.  I hate to do it but I need to be consistent with this
			# now being a instance stage change object.  This used to be a 
			# Net::Amazon::EC2::TerminateInstancesResponse object.
			my $terminated_instance = Net::Amazon::EC2::InstanceStateChange->new(
				instance_id		=> $inst->{instanceId},
				previous_state	=> $previous_state,
				current_state	=> $current_state,
			);
			
			push @$terminated_instances, $terminated_instance;
		}
	
		return $terminated_instances;
	}
}

=head2 unmonitor_instances(%params)

Disables monitoring for a running instance. For more information, refer to the Amazon CloudWatch Developer Guide.

=over

=item InstanceId (required)

The instance id(s) to monitor. Can be a scalar or an array ref

=back

Returns an array ref of Net::Amazon::EC2::MonitoredInstance objects

=cut

sub unmonitor_instances {
	my $self = shift;
	my %args = validate( @_, {
		InstanceId	=> { type => ARRAYREF | SCALAR, optional => 1 },
	});

	# If we have a array ref of instances lets split them out into their InstanceId.n format
	if (ref ($args{InstanceId}) eq 'ARRAY') {
		my $instance_ids	= delete $args{InstanceId};
		my $count					= 1;
		foreach my $instance_id (@{$instance_ids}) {
			$args{"InstanceId." . $count} = $instance_id;
			$count++;
		}
	}
	
	my $xml = $self->_sign(Action  => 'UnmonitorInstances', %args);
	
	if ( grep { defined && length } $xml->{Errors} ) {
		return $self->_parse_errors($xml);
	}
	else {
 		my $monitored_instances;

 		foreach my $monitored_instance_item (@{$xml->{instancesSet}{item}}) {
 			my $monitored_instance = Net::Amazon::EC2::ReservedInstance->new(
				instance_id	=> $monitored_instance_item->{instanceId},
				state		=> $monitored_instance_item->{monitoring}{state},
 			);
 			
 			push @$monitored_instances, $monitored_instance;
 		}
 		
 		return $monitored_instances;
	}
}

no Moose;
1;

__END__

=head1 TESTING

Set AWS_ACCESS_KEY_ID and SECRET_ACCESS_KEY environment variables to run the live tests.  
Note: because the live tests start an instance (and kill it) in both the tests and backwards compat tests there will be 2 hours of 
machine instance usage charges (since there are 2 instances started) which as of February 1st, 2010 costs a total of $0.17 USD

Important note about the windows-only methods.  These have not been well tested as I do not run windows-based instances, so exercise
caution in using these.

=head1 TODO

Need to add in support for Spot Instances.

=head1 AUTHOR

Jeff Kim <cpan@chosec.com>

=head1 CONTRIBUTORS

John McCullough

=head1 COPYRIGHT

Copyright (c) 2006-2010 Jeff Kim. This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 SEE ALSO

Amazon EC2 API: L<http://docs.amazonwebservices.com/AWSEC2/latest/APIReference/>
