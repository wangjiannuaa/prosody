
local md5 = require "md5"
local log = require "util.logger".init("sasl");
local tostring = tostring;
local st = require "util.stanza";
local generate_uuid = require "util.uuid".generate;
local s_match = string.match;
local gmatch = string.gmatch
local string = string
local math = require "math"
local type = type
local error = error
local print = print

module "sasl"

local function new_plain(realm, password_handler)
	local object = { mechanism = "PLAIN", realm = realm, password_handler = password_handler}
	function object.feed(self, message)
        
		if message == "" or message == nil then return "failure", "malformed-request" end
		local response = message
		local authorization = s_match(response, "([^&%z]+)")
		local authentication = s_match(response, "%z([^&%z]+)%z")
		local password = s_match(response, "%z[^&%z]+%z([^&%z]+)")
		
		local password_encoding, correct_password = self.password_handler(authentication, self.realm, "PLAIN")
		
		local claimed_password = ""
		if password_encoding == nil then claimed_password = password
		else claimed_password = password_encoding(password) end
		
		self.username = authentication
		if claimed_password == correct_password then
			log("debug", "success")
			return "success"
		else
			log("debug", "failure")
			return "failure", "not-authorized"
		end
	end
	return object
end

local function new_digest_md5(realm, password_handler)
	--TODO maybe support for authzid

	local function serialize(message)
		local data = ""
		
		if type(message) ~= "table" then error("serialize needs an argument of type table.") end
		
		-- testing all possible values
		if message["nonce"] then data = data..[[nonce="]]..message.nonce..[[",]] end
		if message["qop"] then data = data..[[qop="]]..message.qop..[[",]] end
		if message["charset"] then data = data..[[charset=]]..message.charset.."," end
		if message["algorithm"] then data = data..[[algorithm=]]..message.algorithm.."," end
		if message["realm"] then data = data..[[realm="]]..message.realm..[[",]] end
		if message["rspauth"] then data = data..[[rspauth=]]..message.rspauth.."," end
		data = data:gsub(",$", "")
		return data
	end
	
	local function parse(data)
		message = {}
		log("debug", "parse-message: "..data)
		for k, v in gmatch(data, [[([%w%-]+)="?([%w%-%/%.%+=]+)"?,?]]) do
			message[k] = v
		log("debug", "               "..k.." = "..v)
		end
		return message
	end

	local object = { mechanism = "DIGEST-MD5", realm = realm, password_handler = password_handler}
	
	--TODO: something better than math.random would be nice, maybe OpenSSL's random number generator
	object.nonce = generate_uuid()
	object.step = 0
	object.nonce_count = {}
												
	function object.feed(self, message)
		log("debug", "SASL step: "..self.step)
		self.step = self.step + 1
		if (self.step == 1) then
			local challenge = serialize({	nonce = object.nonce, 
											qop = "auth",
											charset = "utf-8",
											algorithm = "md5-sess",
											realm = self.realm});
			log("debug", "challenge: "..challenge)
			return "challenge", challenge
		elseif (self.step == 2) then
			local response = parse(message)
			-- check for replay attack
			if response["nc"] then
				if self.nonce_count[response["nc"]] then return "failure", "not-authorized" end
			end
			
			-- check for username, it's REQUIRED by RFC 2831
			if not response["username"] then
				return "failure", "malformed-request"
			end
			self["username"] = response["username"] 
			
			-- check for nonce, ...
			if not response["nonce"] then
				return "failure", "malformed-request"
			else
				-- check if it's the right nonce
				if response["nonce"] ~= tostring(self.nonce) then return "failure", "malformed-request" end
			end
			
			if not response["cnonce"] then return "failure", "malformed-request", "Missing entry for cnonce in SASL message." end
			if not response["qop"] then response["qop"] = "auth" end
			
			if response["realm"] == nil then response["realm"] = "" end
			
			local domain = ""
			local protocol = ""
			if response["digest-uri"] then
				protocol, domain = response["digest-uri"]:match("(%w+)/(.*)$")
			else
				return "failure", "malformed-request", "Missing entry for digest-uri in SASL message."
			end
			
			--TODO maybe realm support
			self.username = response["username"]
			local password_encoding, Y = self.password_handler(response["username"], response["realm"], "DIGEST-MD5")
			local A1 = Y..":"..response["nonce"]..":"..response["cnonce"]--:authzid
			local A2 = "AUTHENTICATE:"..protocol.."/"..domain
			
			local HA1 = md5.sumhexa(A1)
			local HA2 = md5.sumhexa(A2)
			
			local KD = HA1..":"..response["nonce"]..":"..response["nc"]..":"..response["cnonce"]..":"..response["qop"]..":"..HA2
			local response_value = md5.sumhexa(KD)
			
			log("debug", "response_value: "..response_value);
			log("debug", "response:       "..response["response"]);
			if response_value == response["response"] then
				-- calculate rspauth
				A2 = ":"..protocol.."/"..domain
				
				HA1 = md5.sumhexa(A1)
				HA2 = md5.sumhexa(A2)
        
				KD = HA1..":"..response["nonce"]..":"..response["nc"]..":"..response["cnonce"]..":"..response["qop"]..":"..HA2
				local rspauth = md5.sumhexa(KD)
				self.authenticated = true
				return "challenge", serialize({rspauth = rspauth})
			else
				return "failure", "not-authorized", "The response provided by the client doesn't match the one we calculated."
			end							
		elseif self.step == 3 then
			if self.authenticated ~= nil then return "success"
			else return "failure", "malformed-request" end
		end
	end
	return object
end

function new(mechanism, realm, password_handler)
	local object
	if mechanism == "PLAIN" then object = new_plain(realm, password_handler)
	elseif mechanism == "DIGEST-MD5" then object = new_digest_md5(realm, password_handler)
	else
		log("debug", "Unsupported SASL mechanism: "..tostring(mechanism));
		return nil
	end
	return object
end

return _M;