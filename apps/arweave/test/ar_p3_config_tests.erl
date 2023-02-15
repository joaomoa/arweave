-module(ar_p3_config_tests).

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_config.hrl").
-include_lib("arweave/include/ar_p3.hrl").

-include_lib("eunit/include/eunit.hrl").

%% @doc The XXX_parse_test() tests assert that a correctly formatted p3 configuration block is
%% correctly parsed. They do *not* validate that the configuration data is semantically
%% correct - that level of business logic validation is asserted elsewhere.
empty_config_parse_test() ->
	Config = <<"{}">>,
	{ok, ParsedConfig} = ar_config:parse(Config),
	ExpectedConfig = [],
	?assertEqual(ExpectedConfig, ParsedConfig#config.services).

no_service_parse_test() ->
	Config = <<"{\"services\": []}">>,
	{ok, ParsedConfig} = ar_config:parse(Config),
	ExpectedConfig = [],
	?assertEqual(ExpectedConfig, ParsedConfig#config.services).

basic_parse_test() ->
	Config = <<"{
		\"services\": [{
			\"endpoint\": \"/info\",
			\"modSeq\": 1,
			\"rates\": {
				\"rate_type\": \"request\",
				\"arweave\": {
					\"AR\": {
						\"price\": \"1000\",
						\"address\": \"abc\"
					}
				}
			}
		},
		{
			\"endpoint\": \"/chunk/{offset}\",
			\"modSeq\": 5,
			\"rates\": {
				\"rate_type\": \"byte\",
				\"arweave\": {
					\"AR\": {
						\"price\": \"100000\",
						\"address\": \"def\"
					}
				}
			}
		}]
	}">>,
	{ok, ParsedConfig} = ar_config:parse(Config),
	ExpectedConfig = [
		#p3_service{
			endpoint = <<"/info">>,
			mod_seq = 1,
			rates = #p3_rates{
				rate_type = <<"request">>,
				arweave = #p3_arweave{
					ar = #p3_ar{
						price = <<"1000">>,
						address = <<"abc">>
					}
				}
			}
		},
		#p3_service{
			endpoint = <<"/chunk/{offset}">>,
			mod_seq = 5,
			rates = #p3_rates{
				rate_type = <<"byte">>,
				arweave = #p3_arweave{
					ar = #p3_ar{
						price = <<"100000">>,
						address = <<"def">>
					}
				}
			}
		}
	],
	?assertEqual(ExpectedConfig, ParsedConfig#config.services).

%% @doc The XXX_parse_error_test() tests assert that an incorrectly formatted p3 configuration
%% block triggers an error during config file load. They do consider semantic or business
%% logic errors.
no_service_list_parse_error_test() ->
	Config = <<"{
		\"services\": {
			\"endpoint\": \"/info\",
			\"modSeq\": 1,
			\"rates\": {
				\"rate_type\": \"request\",
				\"arweave\": {
					\"AR\": {
						\"price\": \"1000\",
						\"address\": \"abc\"
					}
				}
			}
		}
	}">>,
	?assertMatch(
		{error, {bad_format, services, _}, _}, ar_config:parse(Config)).

bad_service_token_parse_error_test() ->
	Config = <<"{
		\"services\": [{
			\"endpoint\": \"/info\",
			\"modSeq\": 1,
			\"invalid\": \"value\",
			\"rates\": {
				\"rate_type\": \"request\",
				\"arweave\": {
					\"AR\": {
						\"price\": \"1000\",
						\"address\": \"abc\"
					}
				}
			}
		}]
	}">>,
	?assertMatch(
		{error, {bad_format, services, _}, _}, ar_config:parse(Config)).

modseq_not_integer_parse_error_test() ->
	Config = <<"{
		\"services\": [{
			\"endpoint\": \"/info\",
			\"modSeq\": \"1\",
			\"rates\": {
				\"rate_type\": \"request\",
				\"arweave\": {
					\"AR\": {
						\"price\": \"1000\",
						\"address\": \"abc\"
					}
				}
			}
		}]
	}">>,
	?assertMatch(
		{error, {bad_format, services, _}, _}, ar_config:parse(Config)).

bad_rates_token_parse_error_test() ->
	Config = <<"{
		\"services\": [{
			\"endpoint\": \"/info\",
			\"modSeq\": 1,
			\"rates\": {
				\"rate_type\": \"request\",
				\"invalid\": \"value\",
				\"arweave\": {
					\"AR\": {
						\"price\": \"1000\",
						\"address\": \"abc\"
					}
				}
			}
		}]
	}">>,
	?assertMatch(
		{error, {bad_format, services, _}, _}, ar_config:parse(Config)).

bad_arweave_token_parse_error_test() ->
	Config = <<"{
		\"services\": [{
			\"endpoint\": \"/info\",
			\"modSeq\": 1,
			\"rates\": {
				\"rate_type\": \"request\",
				\"arweave\": {
					\"invalid\": \"value\",
					\"AR\": {
						\"price\": \"1000\",
						\"address\": \"abc\"
					}
				}
			}
		}]
	}">>,
	?assertMatch(
		{error, {bad_format, services, _}, _}, ar_config:parse(Config)).


bad_ar_token_parse_error_test() ->
	Config = <<"{
		\"services\": [{
			\"endpoint\": \"/info\",
			\"modSeq\": 1,
			\"rates\": {
				\"rate_type\": \"request\",
				\"arweave\": {
					\"AR\": {
						\"price\": \"1000\",
						\"address\": \"abc\",
						\"invalid\": \"value\"
					}
				}
			}
		}]
	}">>,
	?assertMatch(
		{error, {bad_format, services, _}, _}, ar_config:parse(Config)).

no_services_validate_test() ->
	ServicesConfig = [],
	?assertEqual(
		{ok, ServicesConfig},
		ar_p3:validate_config(config_fixture(ServicesConfig))).

basic_validate_test() ->
	ServicesConfig = [
		#p3_service{
			endpoint = <<"/info">>,
			mod_seq = 1,
			rates = #p3_rates{
				rate_type = <<"request">>,
				arweave = #p3_arweave{
					ar = #p3_ar{
						price = <<"1000">>,
						address = <<"abc">>
					}
				}
			}
		},
		#p3_service{
			endpoint = <<"/chunk/{offset}">>,
			mod_seq = 5,
			rates = #p3_rates{
				rate_type = <<"byte">>,
				arweave = #p3_arweave{
					ar = #p3_ar{
						price = <<"100000">>,
						address = <<"def">>
					}
				}
			}
		}
	],
	?assertEqual(
		{ok, ServicesConfig},
		ar_p3:validate_config(config_fixture(ServicesConfig))).

no_endpoint_validate_test() ->
	ServicesConfig = [
		#p3_service{
			mod_seq = 1,
			rates = #p3_rates{
				rate_type = <<"request">>,
				arweave = #p3_arweave{
					ar = #p3_ar{
						price = <<"1000">>,
						address = <<"abc">>
					}
				}
			}
		}
	],
	?assertMatch(
		{stop, _},
	 	ar_p3:validate_config(config_fixture(ServicesConfig))).

bad_endpoint_validate_test() ->
	ServicesConfig = [
		#p3_service{
			endpoint = <<"https://mydomain.com/info">>,
			mod_seq = 1,
			rates = #p3_rates{
				rate_type = <<"request">>,
				arweave = #p3_arweave{
					ar = #p3_ar{
						price = <<"1000">>,
						address = <<"abc">>
					}
				}
			}
		}
	],
	?assertMatch(
		{stop, _},
	 	ar_p3:validate_config(config_fixture(ServicesConfig))).

no_mod_seq_validate_test() ->
	ServicesConfig = [
		#p3_service{
			endpoint = <<"/info">>,
			rates = #p3_rates{
				rate_type = <<"request">>,
				arweave = #p3_arweave{
					ar = #p3_ar{
						price = <<"1000">>,
						address = <<"abc">>
					}
				}
			}
		}
	],
	?assertMatch(
		{stop, _},
	 	ar_p3:validate_config(config_fixture(ServicesConfig))).

bad_mod_seq_validate_test() ->
	ServicesConfig = [
		#p3_service{
			endpoint = <<"/info">>,
			mod_seq = "1",
			rates = #p3_rates{
				rate_type = <<"request">>,
				arweave = #p3_arweave{
					ar = #p3_ar{
						price = <<"1000">>,
						address = <<"abc">>
					}
				}
			}
		}
	],
	?assertMatch(
		{stop, _},
	 	ar_p3:validate_config(config_fixture(ServicesConfig))).

no_rates_validate_test() ->
	ServicesConfig = [
		#p3_service{
			endpoint = <<"/info">>,
			mod_seq = 1
		}
	],
	?assertMatch(
		{stop, _},
	 	ar_p3:validate_config(config_fixture(ServicesConfig))).

bad_rates_validate_test() ->
	ServicesConfig = [
		#p3_service{
			endpoint = <<"/info">>,
			mod_seq = 1,
			rates = 1
		}
	],
	?assertMatch(
		{stop, _},
	 	ar_p3:validate_config(config_fixture(ServicesConfig))).

no_rate_type_validate_test() ->
	ServicesConfig = [
		#p3_service{
			endpoint = <<"/info">>,
			mod_seq = 1,
			rates = #p3_rates{
				arweave = #p3_arweave{
					ar = #p3_ar{
						price = <<"1000">>,
						address = <<"abc">>
					}
				}
			}
		}
	],
	?assertMatch(
		{stop, _},
	 	ar_p3:validate_config(config_fixture(ServicesConfig))).

bad_rate_type_validate_test() ->
	ServicesConfig = [
		#p3_service{
			endpoint = <<"/info">>,
			mod_seq = 1,
			rates = #p3_rates{
				rate_type = "invalid",
				arweave = #p3_arweave{
					ar = #p3_ar{
						price = <<"1000">>,
						address = <<"abc">>
					}
				}
			}
		}
	],
	?assertMatch(
		{stop, _},
	 	ar_p3:validate_config(config_fixture(ServicesConfig))).

no_arweave_validate_test() ->
	ServicesConfig = [
		#p3_service{
			endpoint = <<"/info">>,
			mod_seq = 1,
			rates = #p3_rates{
				rate_type = <<"request">>
			}
		}
	],
	?assertMatch(
		{stop, _},
	 	ar_p3:validate_config(config_fixture(ServicesConfig))).

bad_arweave_validate_test() ->
	ServicesConfig = [
		#p3_service{
			endpoint = <<"/info">>,
			mod_seq = 1,
			rates = #p3_rates{
				rate_type = <<"request">>,
				arweave = 1
			}
		}
	],
	?assertMatch(
		{stop, _},
	 	ar_p3:validate_config(config_fixture(ServicesConfig))).


no_ar_validate_test() ->
	ServicesConfig = [
		#p3_service{
			endpoint = <<"/info">>,
			mod_seq = 1,
			rates = #p3_rates{
				rate_type = <<"request">>,
				arweave = #p3_arweave{
				}
			}
		}
	],
	?assertMatch(
		{stop, _},
	 	ar_p3:validate_config(config_fixture(ServicesConfig))).

bad_ar_validate_test() ->
	ServicesConfig = [
		#p3_service{
			endpoint = <<"/info">>,
			mod_seq = 1,
			rates = #p3_rates{
				rate_type = <<"request">>,
				arweave = #p3_arweave{
					ar = #{}
				}
			}
		}
	],
	?assertMatch(
		{stop, _},
	 	ar_p3:validate_config(config_fixture(ServicesConfig))).

no_ar_price_validate_test() ->
	ServicesConfig = [
		#p3_service{
			endpoint = <<"/info">>,
			mod_seq = 1,
			rates = #p3_rates{
				rate_type = <<"request">>,
				arweave = #p3_arweave{
					ar = #p3_ar{
						address = <<"abc">>
					}
				}
			}
		}
	],
	?assertMatch(
		{stop, _},
	 	ar_p3:validate_config(config_fixture(ServicesConfig))).

bad_ar_price_validate_test() ->
	ServicesConfig = [
		#p3_service{
			endpoint = <<"/info">>,
			mod_seq = 1,
			rates = #p3_rates{
				rate_type = <<"request">>,
				arweave = #p3_arweave{
					ar = #p3_ar{
						price = <<"abc">>,
						address = <<"abc">>
					}
				}
			}
		}
	],
	?assertMatch(
		{stop, _},
	 	ar_p3:validate_config(config_fixture(ServicesConfig))).

string_ar_price_validate_test() ->
	ServicesConfig = [
		#p3_service{
			endpoint = <<"/info">>,
			mod_seq = 1,
			rates = #p3_rates{
				rate_type = <<"request">>,
				arweave = #p3_arweave{
					ar = #p3_ar{
						price = "1000",
						address = <<"abc">>
					}
				}
			}
		}
	],
	?assertMatch(
		{stop, _},
	 	ar_p3:validate_config(config_fixture(ServicesConfig))).

integer_ar_price_validate_test() ->
	ServicesConfig = [
		#p3_service{
			endpoint = <<"/info">>,
			mod_seq = 1,
			rates = #p3_rates{
				rate_type = <<"request">>,
				arweave = #p3_arweave{
					ar = #p3_ar{
						price = 1000,
						address = <<"abc">>
					}
				}
			}
		}
	],
	?assertMatch(
		{stop, _},
	 	ar_p3:validate_config(config_fixture(ServicesConfig))).

no_ar_address_validate_test() ->
	ServicesConfig = [
		#p3_service{
			endpoint = <<"/info">>,
			mod_seq = 1,
			rates = #p3_rates{
				rate_type = <<"request">>,
				arweave = #p3_arweave{
					ar = #p3_ar{
						price = <<"1000">>
					}
				}
			}
		}
	],
	?assertMatch(
		{stop, _},
	 	ar_p3:validate_config(config_fixture(ServicesConfig))).

bad_ar_address_validate_test() ->
	ServicesConfig = [
		#p3_service{
			endpoint = <<"/info">>,
			mod_seq = 1,
			rates = #p3_rates{
				rate_type = <<"request">>,
				arweave = #p3_arweave{
					ar = #p3_ar{
						price = <<"1000">>,
						address = <<"no good">>
					}
				}
			}
		}
	],
	?assertMatch(
		{stop, _},
	 	ar_p3:validate_config(config_fixture(ServicesConfig))).


config_fixture(Services) ->
	#config{ services = Services }.