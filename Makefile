PROJECT = mdns

DEPS = gproc lager lists2
dep_gproc = https://github.com/uwiger/gproc.git master
dep_lager = https://github.com/erlang-lager/lager.git master
dep_lists2 = https://github.com/jlouis/lists2.git master

ERLC_OPTS = +debug_info +'{parse_transform, lager_transform}'

include erlang.mk

