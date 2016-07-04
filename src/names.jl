#==============================================================================#
# names.jl
#
# AWS Endpoint URLs and Amazon Resource Names.
#
# http://docs.aws.amazon.com/general/latest/gr/rande.html
# http://docs.aws.amazon.com/general/latest/gr/aws-arns-and-namespaces.html
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


export aws_endpoint, arn, arn_region



#------------------------------------------------------------------------------#
# AWS Endpoint URLs
#
# e.g.
#
#   aws_endpoint("sqs", "eu-west-1")
#   "http://sqs.eu-west-1.amazonaws.com"
#
#------------------------------------------------------------------------------#


function aws_endpoint(service, region="", hostname_prefix="")

    protocol = "http"

    # HTTPS where required...
    if service in ["iam", "sts", "lambda", "apigateway", "email"]
        protocol = "https"
    end

    # Identity and Access Management API has no region suffix...
    if service == "iam"
        region = ""
    end

    # SES not available in all regions...
    if service == "ses" && !(region in ["us-east-1", "us-west-2", "eu-west-1"])
        region = "us-east-1"
    end

    # No region sufix for s3 or sdb in default region...
    if region == "us-east-1" && service in ["s3", "sdb"]
        region = ""
    end

    # Append region to service...
    if region != ""
        if service == "s3"
            service = "$service-$region"
        else
            service = "$service.$region"
        end
    end

    # Add optional hostname prefix (e.g. S3 Bucket Name)...
    if hostname_prefix != ""
        service = "$hostname_prefix.$service"
    end

    return "$protocol://$service.amazonaws.com"
end



#------------------------------------------------------------------------------#
# Amazon Resource Names
#------------------------------------------------------------------------------#


function arn(service, resource, region="", account="")

    if service == "s3"
        region = ""
        account = ""
    elseif service == "iam"
        region = ""
    end

    "arn:aws:$service:$region:$account:$resource"
end


function arn(aws::SymbolDict,
             service,
             resource,
             region=get(aws, :region, ""),
             account=aws_account_number(aws))

    arn(service, resource, region, account)
end


arn_region(arn) = split(arn, ":")[4]


#==============================================================================#
# End of file.
#==============================================================================#
