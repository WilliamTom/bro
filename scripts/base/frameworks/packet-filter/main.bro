##! This script supports how Bro sets it's BPF capture filter.  By default
##! Bro sets a capture filter that allows all traffic.  If a filter
##! is set on the command line, that filter takes precedence over the default
##! open filter and all filters defined in Bro scripts with the
##! :bro:id:`capture_filters` and :bro:id:`restrict_filters` variables.

@load base/frameworks/notice
@load base/frameworks/protocols

module PacketFilter;

export {
	## Add the packet filter logging stream.
	redef enum Log::ID += { LOG };

	## Add notice types related to packet filter errors.
	redef enum Notice::Type += {
		## This notice is generated if a packet filter is unable to be compiled.
		Compile_Failure,
	
		## This notice is generated if a packet filter is fails to install.
		Install_Failure,
		
		## Generated when a notice takes too long to compile.
		Too_Long_To_Compile_Filter
	};

	## The record type defining columns to be logged in the packet filter
	## logging stream.
	type Info: record {
		## The time at which the packet filter installation attempt was made.
		ts:     time   &log;
		
		## This is a string representation of the node that applied this
		## packet filter.  It's mostly useful in the context of dynamically
		## changing filters on clusters.
		node:   string &log &optional;
		
		## The packet filter that is being set.
		filter: string &log;
		
		## Indicate if this is the filter set during initialization.
		init:   bool   &log &default=F;
		
		## Indicate if the filter was applied successfully.
		success: bool  &log &default=T;
	};
	
	## The BPF filter that is used by default to define what traffic should
	## be captured.  Filters defined in :bro:id:`restrict_filters` will still
	## be applied to reduce the captured traffic.
	const default_capture_filter = "ip or not ip" &redef;
	
	## Filter string which is unconditionally or'ed to the beginning of every 
	## dynamically built filter.
	const unrestricted_filter = "" &redef;
	
	## The maximum amount of time that you'd like to allow for filters to compile.
	## If this time is exceeded, compensation measures may be taken by the framework
	## to reduce the filter size.  This threshold being crossed also results in
	## the :bro:enum:`PacketFilter::Too_Long_To_Compile_Filter` notice.
	const max_filter_compile_time = 100msec &redef;
	
	## Install a BPF filter to exclude some traffic.  The filter should positively
	## match what is to be excluded, it will be wrapped in a "not".
	##
	## filter_id: A somewhat arbitrary string that can be used to identify 
	##            the filter.
	##
	## filter: A BPF expression of traffic that should be excluded.
	##
	## Returns: A boolean value to indicate if the fitler was successfully
	##          installed or not.
	global exclude: function(filter_id: string, filter: string): bool;
	
	## Install a temporary filter to traffic which should not be passed through
	## the BPF filter.  The filter should match the traffic you don't want
	## to see (it will be wrapped in a "not" condition).
	##
	## filter_id: A somewhat arbitrary string that can be used to identify 
	##            the filter.
	##
	## filter: A BPF expression of traffic that should be excluded.
	##
	## length: The duration for which this filter should be put in place.
	##
	## Returns: A boolean value to indicate if the filter was successfully 
	##          installed or not.
	global exclude_for: function(filter_id: string, filter: string, span: interval): bool;
	
	## Call this function to build and install a new dynamically built
	## packet filter.
	global install: function();
	
	## A data structure to represent filter generating factories.
	type FilterFactory: record {
		## A function that is directly called when generating the complete filter.
		func : function();
	};
	
	## API function to register a new factory for dynamic restriction filters.
	global register_filter_factory: function(ff: FilterFactory);
	
	## Enables the old filtering approach of "only watch common ports for 
	## analyzed protocols".
	## Unless you know what you are doing, leave this set to F.
	const enable_auto_protocol_capture_filters = F &redef;
	
	## This is where the default packet filter is stored and it should not 
	## normally be modified by users.
	global current_filter = "<not set yet>";
}

global dynamic_restrict_filters: table[string] of string = {};

# Set the default capture filter.
redef capture_filters += { ["default"] = default_capture_filter };

# Track if a filter is currenlty building so functions that would ultimately 
# install a filter immediately can still be used buy they won't try to build or
# install the filter.
global currently_building = F;

global filter_factories: set[FilterFactory] = {};

redef enum PcapFilterID += {
	DefaultPcapFilter,
	FilterTester,
};

function test_filter(filter: string): bool
	{
	if ( ! precompile_pcap_filter(FilterTester, filter) )
		{
		# The given filter was invalid
		# TODO: generate a notice.
		return F;
		}
	return T;
	}

event bro_init() &priority=6
	{
	Log::create_stream(PacketFilter::LOG, [$columns=Info]);
	
	# Preverify the capture and restrict filters to give more granular failure messages.
	for ( id in capture_filters )
		{
		if ( ! test_filter(capture_filters[id]) )
			Reporter::fatal(fmt("Invalid capture_filter named '%s' - '%s'", id, capture_filters[id]));
		}
		
	for ( id in restrict_filters )
		{
		if ( ! test_filter(restrict_filters[id]) )
			Reporter::fatal(fmt("Invalid restrict filter named '%s' - '%s'", id, restrict_filters[id]));
		}
	
	install();
	}
	
function register_filter_factory(ff: FilterFactory)
	{
	add filter_factories[ff];
	}

event remove_dynamic_filter(filter_id: string)
	{
	if ( filter_id in dynamic_restrict_filters )
		{
		delete dynamic_restrict_filters[filter_id];
		install();
		}
	}

function exclude(filter_id: string, filter: string): bool
	{
	if ( ! test_filter(filter) )
		return F;
		
	dynamic_restrict_filters[filter_id] = filter;
	install();
	return T;
	}

function exclude_for(filter_id: string, filter: string, span: interval): bool
	{
	if ( exclude(filter_id, filter) )
		{
		schedule span { remove_dynamic_filter(filter_id) };
		return T;
		}
	return F;
	}

function build(): string
	{
	if ( cmd_line_bpf_filter != "" )
		# Return what the user specified on the command line;
		return cmd_line_bpf_filter;
	
	currently_building = T;
	
	# Install the default capture filter.
	local cfilter = "";
	
	if ( |capture_filters| == 0 && ! enable_auto_protocol_capture_filters )
		cfilter = default_capture_filter;
		
	for ( id in capture_filters )
		cfilter = combine_filters(cfilter, "or", capture_filters[id]);
	
	if ( enable_auto_protocol_capture_filters )
		cfilter = combine_filters(cfilter, "or", Protocols::to_bpf());
	
	# Apply the restriction filters.
	local rfilter = "";
	for ( id in restrict_filters )
		rfilter = combine_filters(rfilter, "and", restrict_filters[id]);
	
	# Apply the dynamic restriction filters.
	for ( filt in dynamic_restrict_filters )
		rfilter = combine_filters(rfilter, "and", string_cat("not (", dynamic_restrict_filters[filt], ")"));

	# Generate all of the plugin factory based filters.
	for ( factory in filter_factories )
		{
		factory$func();
		}
	
	# Finally, join them into one filter.
	local filter = combine_filters(cfilter, "and", rfilter);
	
	if ( unrestricted_filter != "" )
		filter = combine_filters(unrestricted_filter, "or", filter);
	
	currently_building = F;
	return filter;
	}

function install()
	{
	if ( currently_building )
		return;
	
	current_filter = build();
	
	#local ts = current_time();
	if ( ! precompile_pcap_filter(DefaultPcapFilter, current_filter) )
		{
		NOTICE([$note=Compile_Failure,
		        $msg=fmt("Compiling packet filter failed"),
		        $sub=current_filter]);
		Reporter::fatal(fmt("Bad pcap filter '%s'", current_filter));
		}
	
	#local diff = current_time()-ts;
	#if ( diff > max_filter_compile_time )
	#	NOTICE([$note=Too_Long_To_Compile_Filter,
	#	        $msg=fmt("A BPF filter is taking longer than %0.6f seconds to compile", diff)]);
	
	# Do an audit log for the packet filter.
	local info: Info;
	info$ts = network_time();
	# If network_time() is 0.0 we're at init time so use the wall clock.
	if ( info$ts == 0.0 )
		{
		info$ts = current_time();
		info$init = T;
		}
	info$filter = current_filter;
	
	if ( ! install_pcap_filter(DefaultPcapFilter) )
		{
		# Installing the filter failed for some reason.
		info$success = F;
		NOTICE([$note=Install_Failure,
		        $msg=fmt("Installing packet filter failed"),
		        $sub=current_filter]);
		}
		
	
	if ( reading_live_traffic() || reading_traces() )
		Log::write(PacketFilter::LOG, info);
	}
