%% @author Uvarov Michael <arcusfelis@gmail.com>
%% @doc
%% Large packets are splited into chunks.
%%
%% Peer sends advertisment with TTL=0 before exiting.
%% Example of this from annlist:
%%
%% ```
%% #dns_rr{domain = "4d336d342d312d2d343834616435313564343437._bittorrent._tcp.local",
%%      type = srv,class = 32769,cnt = 0,ttl = 0,
%%      data = {0,0,555,"omicron.local"},
%%      tm = undefined,bm = [],func = false}
%% '''
%%
%% @end
-module(mdns_net).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include_lib("kernel/src/inet_dns.hrl").

-behaviour(gen_server).
-compile({parse_transform, lager_transform}).


% Public interface
-export([start_link/4,
         request_service/1,
         unrequest_service/1,
         publish_service/3,
         publish_service/4,
         unpublish_service/3,
         unpublish_service/4]).

% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {
    socket :: inet:socket(),
    host_name :: string(),
    domain :: string(),
    requested_services :: [string()],
    published_services :: [string()],
    broadcast_ip,
    broadcast_port,
    %% This dict is used to merge a series of packets from one sender.
    %% Contains pairs of `{IP, {TRef, Rec=#dns_rec{}}}'.
    waiting_dict :: dict:dict(),
    request :: inet_dns:dns_rec()
}).

%
% Type definitions and function specifications
%


%
% Contacts and settings
%
srv_name() ->
   mdns_socket_server.

waiting_timeout() ->
    300.

request_timeout() ->
    300.

socket_options(MulticastIP, InterfaceIP0) ->
    InterfaceIP = case InterfaceIP0 of
             undefined -> {0,0,0,0};
             auto -> multicast_if();
             _ -> InterfaceIP0
         end,
    lager:info("Multicast interface is ~p.", [InterfaceIP]),
    lager:info("Listen address is ~p.", [MulticastIP]),
    [{multicast_if, InterfaceIP},
     {reuseaddr, true},
     {multicast_ttl,4},
%    {multicast_loop,false},
%    {broadcast, true},
     {active, true},
     {mode, binary},
     {ip, MulticastIP},
     {add_membership,{MulticastIP, InterfaceIP}}].

%
% Public interface
%
start_link(MulticastIP, InterfaceIP, ListenPort, Domain) ->
    Args = [MulticastIP, InterfaceIP, ListenPort, Domain],
    gen_server:start_link({local, srv_name()}, ?MODULE, Args, []).

request_service(ServiceType) ->
    gen_server:call(srv_name(), {request_service, ServiceType}).
  
unrequest_service(ServiceType) ->
    gen_server:call(srv_name(), {unrequest_service, ServiceType}).

%% @doc Publish a service.
%% `avahi-publish-service 4d336d342d312d2d343834616435313564343437 _bittorrent._tcp 555'
%e will be `mdns_net:publish_service("4d336d342d312d2d343834616435313564343437", "_bittorrent._tcp", 555)'.
publish_service(Name, ServiceType, Port) ->
    publish_service(Name, ServiceType, Port, []).

publish_service(Name, ServiceType, Port, SubServices) ->
    gen_server:call(srv_name(), {publish_service, Name, ServiceType, Port, SubServices}).


unpublish_service(Name, ServiceType, Port) ->
    unpublish_service(Name, ServiceType, Port, []).

unpublish_service(Name, ServiceType, Port, SubServices) ->
    gen_server:call(srv_name(), {unpublish_service, Name, ServiceType, Port, SubServices}).
    

%% ==================================================================

init([MulticastIP, InterfaceIP, ListenPort, Domain]) ->
    {ok, Socket} = gen_udp:open(ListenPort,
                                socket_options(MulticastIP, InterfaceIP)),
    %% TODO: We want "omicron.local", this call returns "omicron.lan".
    HostName = net_adm:localhost(),
    State = #state{socket=Socket,
                   domain=Domain,
                   requested_services=[],
                   published_services=[],
                   host_name=HostName,
                   broadcast_ip=MulticastIP,
                   broadcast_port=ListenPort,
                   waiting_dict=dict:new(),
                   request=#dns_rec{header=#dns_header{}, qdlist=[]}},
    {ok, State}.

handle_call({request_service, ServiceType}, _From,
            State=#state{request=ReqRec, domain=Domain,
                         requested_services=ServiceTypes}) ->
    #dns_rec{qdlist=QDList} = ReqRec,
    PtrDomain = ServiceType ++ "." ++ Domain,
    DNSQuery = #dns_query{domain=PtrDomain, type=any, class=in},
    NewServiceTypes=append_new(ServiceType, ServiceTypes),
    NewState = State#state{requested_services=NewServiceTypes},
    case QDList of
        [] ->
            erlang:send_after(request_timeout(), self(), request_timeout),
            {reply, ok, NewState#state{request=ReqRec#dns_rec{qdlist=[DNSQuery]}}};
        _ ->
            NewReqRec = ReqRec#dns_rec{qdlist=append_new(DNSQuery, QDList)},
            {reply, ok, NewState#state{request=NewReqRec}}
    end;

handle_call({unrequest_service, _ServiceType}, _From, State) ->
  {reply, ok, State};

handle_call({publish_service, Name, ServiceType, Port, SubServices}, _From,
            State=#state{socket=Socket, host_name=HostName, domain=Domain,
                         broadcast_ip=BIP, broadcast_port=BPort,
                         published_services=ServiceTypes}) ->
    SrvDomain = service_srv_domain(Name, ServiceType, Domain),
    PtrDomain = service_ptr_domain(ServiceType, Domain),
    ReqRec = #dns_rec{
        header = query_packet_header(),
        qdlist = [service_in_dns_query(SrvDomain)],
        nslist = [service_srv_in_dns_rr(SrvDomain, HostName, Port, true)]},
    ResRec = #dns_rec{
        header = query_packet_header(),
        anlist =  [service_ptr_dns_rr(
                      sub_service_ptr_domain(SubServiceName, ServiceType, Domain),
                      SrvDomain, true)
                   || SubServiceName <- SubServices] ++
                  [service_ptr_dns_rr(PtrDomain, SrvDomain, true),
                   services_in_dns_rr(Domain, PtrDomain, true),
                   service_srv_dns_rr(SrvDomain, HostName, Port, true)]},
    gen_udp:send(Socket, BIP, BPort, inet_dns:encode(ReqRec)),
    gen_udp:send(Socket, BIP, BPort, inet_dns:encode(ResRec)),
    NewServiceTypes=append_new(ServiceType, ServiceTypes),
    {reply, ok, State#state{published_services=NewServiceTypes}};

handle_call({unpublish_service, Name, ServiceType, Port, SubServices}, _From,
            State=#state{socket=Socket, host_name=HostName, domain=Domain,
                         broadcast_ip=BIP, broadcast_port=BPort,
                         published_services=PublishedServices}) ->
    SrvDomain = service_srv_domain(Name, ServiceType, Domain),
    PtrDomain = service_ptr_domain(ServiceType, Domain),
    ResRec = #dns_rec{
        header = query_packet_header(),
        anlist =  [service_ptr_dns_rr(
                      sub_service_ptr_domain(SubServiceName, ServiceType, Domain),
                      SrvDomain, false)
                   || SubServiceName <- SubServices] ++
                  [service_ptr_dns_rr(PtrDomain, SrvDomain, false),
                   services_in_dns_rr(Domain, PtrDomain, false),
                   service_srv_dns_rr(SrvDomain, HostName, Port, false)]},
    gen_udp:send(Socket, BIP, BPort, inet_dns:encode(ResRec)),
    NewPublishedServices=lists:delete(ServiceType, PublishedServices),
    {reply, ok, State#state{published_services=NewPublishedServices}}.


handle_cast(not_implemented, State) ->
    {noreply, State}.


handle_info({udp, _Socket, IP, Port, Packet},
            #state{waiting_dict=WaitingDict} = State) ->
    lager:debug("Receiving a packet from ~p:~p of size ~B~n",
                [IP, Port, byte_size(Packet)]),
    case inet_dns:decode(Packet) of
        {ok, Rec} ->
            lager:debug("Decoded ~s~n", [pretty(Rec)]),
            TRef = erlang:send_after(
                waiting_timeout(), self(), {waiting_timeout, IP}),
            WaitingDict1 = dict:update(
                IP, %% key
                fun({OldTRef, OldRec}) -> %% called, if the key exists.
                    erlang:cancel_timer(OldTRef),
                    {TRef, merge_records(OldRec, Rec)}
                end,
                {TRef, Rec}, %% initial.
                WaitingDict),
            {noreply, State#state{waiting_dict=WaitingDict1}};
        {error, Reason} ->
            lager:debug("Decoding failed with reason ~p", [Reason]),
            {noreply, State}
    end;

handle_info(request_timeout,
            State=#state{socket=Socket, broadcast_ip=BIP,
                         broadcast_port=BPort, request=ReqRec}) ->
    gen_udp:send(Socket, BIP, BPort, inet_dns:encode(ReqRec)),
    {noreply, State#state{request=ReqRec#dns_rec{qdlist=[]}}};

handle_info({waiting_timeout, IP},
            #state{waiting_dict=WaitingDict, domain=Domain,
                   requested_services=RequestedServices,
                   published_services=PublishedServices} = State) ->
    {_TRef, Rec} = dict:fetch(IP, WaitingDict),
    WaitingDict1 = dict:erase(IP, WaitingDict),
    Rec1 = normalize_record(Rec),
    inspect_respond_packet(Rec1, IP, Domain, RequestedServices),
    inspect_request_packet(Rec1, IP, Domain, PublishedServices),
    {noreply, State#state{waiting_dict=WaitingDict1}}.

terminate(_, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ==================================================================

%% ======================================================================
%% Helpers for debugging.

pretty(Term) ->
    io_lib_pretty:print(Term, fun record_definition/2).

record_definition(Name, FieldCount) ->
%   io:format(user, "record_definition(~p, ~p)~n", [Name, FieldCount]),
%   io:format(user, "record_definition_list() = ~p~n", [record_definition_list()]),
    record_definition_1(Name, FieldCount+1, record_definition_list()).

record_definition_1(Name, Size, [{Name, Size, Fields}|_]) ->
    Fields;
record_definition_1(Name, Size, [{_, _, _}|T]) ->
    record_definition_1(Name, Size, T);
record_definition_1(_Name, _Size, []) ->
    no.


-define(REC_DEF(Name),
        {Name, record_info(size, Name), record_info(fields, Name)}).

record_definition_list() ->
    [?REC_DEF(state)
    ,?REC_DEF(dns_rec)
    ,?REC_DEF(dns_header)
    ,?REC_DEF(dns_rr)
    ,?REC_DEF(dns_query)
    ].


%% ======================================================================
%% Detect interface for multicast.

multicast_if() ->
    {ok, Interfaces} = inet:getifaddrs(),
    multicast_if(Interfaces).

multicast_if([]) ->
    undefined;
multicast_if([{_, H} | T]) ->
    case is_running_multicast_interface(proplists:get_value(flags, H)) andalso proplists:is_defined(addr, H) of
        true ->
            v4(proplists:get_all_values(addr, H));
        false ->
            multicast_if(T)
    end.

v4([{_, _, _, _} = V4 | _]) ->
    V4;
v4([_ | T]) ->
    v4(T).

is_running_multicast_interface(Flags) ->
    lists:member(up, Flags) andalso
        lists:member(broadcast, Flags) andalso
        lists:member(running, Flags) andalso
        lists:member(multicast, Flags).


%% ======================================================================
%% MDNS

query_packet_header() ->
    #dns_header{
        id = 0,
        qr = true,
        opcode = 'query',
        aa = true,
        tc = false,
        rd = false,
        ra = false,
        pr = false,
        rcode = 0}.


%% #dns_rr{
%% domain = "4d336d342d312d2d343834616435313564343437._bittorrent._tcp.local",
%% type = srv,class = 32769,cnt = 0,ttl = 120,
%% data = {0,0,555,"omicron.local"},
%% tm = undefined,bm = [],func = false}
service_srv_dns_rr(SrvDomain, HostName, Port, IsEnable) ->
    %% Hack.
    %% a 2-byte class field (hex 80 01 for Ethernet).
    %% A inet_dns does not allow to encode data as `{Prio,Weight,Port,Target}'.
    %%
    %% For class = srv, inet_dns calls
    %% `encode_name(Bin, Comp, Pos, Name)'.
    %% where
    %% Bin = target binary
    %% Comp = compression lookup table; label list -> buffer position
    %% Pos = position in DNS message
    %% Name = domain name to encode
    %% as
    %% `encode_name(<<Prio:16,Weight:16,Port:16>>, Comp, Pos+2+2+2, Target)'.
    %%
    %% For class = 32769, it calls `{iolist_to_binary(Data),Comp}'.
    #dns_rr{
        domain = SrvDomain,
        type = srv,
        class = 32769,
        cnt = 0,
        ttl = case IsEnable of true -> 120; false -> 0 end,
        data = encode_data({0,0,Port,HostName}),
        tm = undefined,
        bm = [],
        func = false}.

%% Ignore `HostName'.
encode_data({Prio,Weight,Port,_HostName}) ->
    <<Prio:16,Weight:16,Port:16,0>>.

service_srv_in_dns_rr(SrvDomain, HostName, Port, IsEnable) ->
    #dns_rr{
        domain = SrvDomain,
        type = srv,
        class = in,
        cnt = 0,
        ttl = case IsEnable of true -> 120; false -> 0 end,
        data = {0,0,Port,HostName},
        tm = undefined,
        bm = [],
        func = false}.

%% #dns_rr{domain = "_bittorrent._tcp.local",type = ptr,
%% class = in,cnt = 0,ttl = 4500,
%% data = "4d336d342d312d2d343834616435313564343437._bittorrent._tcp.local",
%% tm = undefined,bm = [],func = false},
service_ptr_dns_rr(PtrDomain, SrvDomain, IsEnable) ->
    #dns_rr{
        domain = PtrDomain,
        type = ptr,
        class = in,
        cnt = 0,
        ttl = case IsEnable of true -> 4500; false -> 0 end,
        data = SrvDomain,
        tm = undefined,
        bm = [],
        func = false}.

%% #dns_rr{domain = "_services._dns-sd._udp.local",type = ptr,
%% class = in,cnt = 0,ttl = 4500,
%% data = "_bittorrent._tcp.local",tm = undefined,
%% bm = [],func = false}.
services_in_dns_rr(Domain, PtrDomain, IsEnable) ->
    #dns_rr{
        domain = "_services._dns-sd._udp." ++ Domain,
        type = ptr,
        class = in,
        cnt = 0,
        ttl = case IsEnable of true -> 4500; false -> 0 end,
        data = PtrDomain,
        tm = undefined,
        bm = [],
        func = false}.


service_in_dns_query(SrvDomain) ->
    #dns_query{domain = SrvDomain, type = any, class = in}.


service_srv_domain(Name, ServiceType, Domain) ->
    escape_name(Name) ++ "." ++ ServiceType ++ "." ++ Domain.

sub_service_ptr_domain(SubServiceName, ServiceType, Domain) ->
    SubServiceName ++ "._sub." ++ ServiceType ++ "." ++ Domain.

service_ptr_domain(ServiceType, Domain) ->
    ServiceType ++ "." ++ Domain.

service_ptr_domain_to_type(PtrDomain, Domain) ->
    delete_suffix("." ++ Domain, PtrDomain).

service_srv_domain_to_name(SrvDomain, PtrDomain) ->
    delete_suffix("." ++ PtrDomain, SrvDomain).


%% anlist: list of answer entries
%% nslist: list of authority entries
%% qdlist: list of question entries
inspect_respond_packet(#dns_rec{ anlist = RRs }, IP, Domain, ServiceTypes) ->
    [begin
         %% PtrDomain = "_bittorrent._tcp.local"
         %% ServiceType = "_bittorrent._tcp"
         %% SrvDomain = "4d336d342d312d2d343834616435313564343437._bittorrent._tcp.local"
         {SrvTTL, ServicePort} =
             case follow_pointer(SrvDomain, srv, RRs) of
                 {ok, #dns_rr{
                         type = srv, % class = 32769,
                         data = {0,0,Port1,_HostName},
                         ttl = SrvTTL1}} ->
                     {SrvTTL1, Port1};
                 {ok, RR} ->
                     lager:debug("Bad record ~p.", [RR]),
                     {undefined, undefined};
                 {error, _Reason} ->
                     lager:debug("SrvDomain ~p not found.", [SrvDomain]),
                     {undefined, undefined}
             end,
         ServiceName = service_srv_domain_to_name(SrvDomain, PtrDomain),
         SubServiceSuffix = "._sub." ++ ServiceType ++ "." ++ Domain,
         SubServices = extract_subservices(SrvDomain, SubServiceSuffix, RRs),
         [mdns_event:notify_sub_service_down(ServiceName, ServiceType, IP, SubType)
          || {SubType, 0} <- SubServices],
         [mdns_event:notify_sub_service_up(ServiceName, ServiceType, IP, SubType)
          || {SubType, TTL} <- SubServices, TTL > 0],
         
         case SrvTTL of
             undefined ->
                 lager:debug("Ignore service."),
                 ok;
             0 ->
                 mdns_event:notify_service_down(ServiceName, ServiceType, IP, ServicePort);
             _ ->
                 {ok, #dns_rr{domain = SrvDomain, type = txt, data = Txt}} = follow_pointer(SrvDomain, txt, RRs),
                 Data = maps:from_list(lists:map(fun(M) -> split_key_value(M) end, Txt)),
                 mdns_event:notify_service_up(ServiceName, ServiceType, IP, ServicePort, Data)
         end
     end
     || #dns_rr{domain = PtrDomain, type = ptr, class = in,
                data = SrvDomain} <- RRs,
        lists:member(ServiceType = service_ptr_domain_to_type(PtrDomain, Domain),
                     ServiceTypes)].


inspect_request_packet(#dns_rec{qdlist=Qs}, IP, Domain, ServiceTypes) ->
    %% SrvDomain = "4d336d342d312d2d343834616435313564343437._bittorrent._tcp.local"
    %% ServiceName = "4d336d342d312d2d343834616435313564343437"
    %% PtrDomain = "_bittorrent._tcp.local"
    [mdns_event:notify_service_request(ServiceType, IP)
     || #dns_query{type = ptr, domain = PtrDomain} <- Qs,
        lists:member(ServiceType = service_ptr_domain_to_type(PtrDomain, Domain),
                     ServiceTypes)].

-spec follow_pointer(string(), atom(), list(#dns_rr{})) -> {ok, #dns_rr{}} | {error, not_found}.
follow_pointer(Domain, Type, [RR=#dns_rr{type = Type, domain = Domain} | _]) ->
    {ok, RR};
follow_pointer(Domain, Type, [_ | RRs]) ->
    follow_pointer(Domain, Type, RRs);
follow_pointer(_, _, []) ->
    {error, not_found}.
    
extract_subservices(SrvDomain, SubServiceSuffix, 
    [#dns_rr{type = ptr, class=in, data = SrvDomain, domain = SSDomain, ttl=TTL}|RRs]) ->
    case lists:suffix(SubServiceSuffix, SSDomain) of
        true ->
            [{delete_suffix(SubServiceSuffix, SSDomain), TTL}
            |extract_subservices(SrvDomain, SubServiceSuffix, RRs)];
        false ->
            extract_subservices(SrvDomain, SubServiceSuffix, RRs)
    end;
extract_subservices(SrvDomain, SubServiceSuffix, [_|RRs]) ->
    extract_subservices(SrvDomain, SubServiceSuffix, RRs);
extract_subservices(_, _, []) ->
    [].
        
    
escape_name("." ++ Name) ->
    "\\." ++ escape_name(Name);
escape_name("\\" ++ Name) ->
    "\\\\" ++ escape_name(Name);
escape_name([H|Name]) ->
    [H] ++ escape_name(Name);
escape_name("") ->
    "".

split_key_value(Data) ->
    case lists:splitwith(fun(X) -> X =/= $= end, Data) of
        {Key, [$= | Value]} -> {Key, Value};
        {Key, []} -> {Key, true}
    end.


merge_records(R1=#dns_rec{
        qdlist=HQ1,
        anlist=AN1,
        nslist=NS1,
        arlist=AR1
        }, #dns_rec{
        qdlist=HQ2,
        anlist=AN2,
        nslist=NS2,
        arlist=AR2
        }) ->
    R1#dns_rec{
        qdlist=HQ1 ++ HQ2,
        anlist=AN1 ++ AN2,
        nslist=NS1 ++ NS2,
        arlist=AR1 ++ AR2
    }.

normalize_record(R=#dns_rec{
        qdlist=HQ,
        anlist=AN,
        nslist=NS,
        arlist=AR
        }) ->
    R#dns_rec{
        qdlist=lists:usort(HQ),
        anlist=lists:usort(AN),
        nslist=lists:usort(NS),
        arlist=lists:usort(AR)
    }.


append_new(Element, []) ->
    [Element];

append_new(Element, [First|Rest]=List) ->
    if
        Element =:= First -> List;
        true -> [First|append_new(Element, Rest)]
    end.


delete_suffix(_Suffix, []) ->
  [];

delete_suffix(Suffix, String) when Suffix == String ->
  [];

delete_suffix(Suffix, [First | Rest]) ->
  [First | delete_suffix(Suffix, Rest)].
