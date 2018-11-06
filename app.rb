require "sinatra"
require 'sinatra/reloader' if development?

require 'alexa_skills_ruby'
require 'httparty'
require 'iso8601'
require 'json'

require 'twilio-ruby'
require 'giphy'
require 'forecast_io'
require 'giggle'

# ----------------------------------------------------------------------

# Load environment variables using Dotenv. If a .env file exists, it will
# set environment variables from that file (useful for dev environments)
configure :development do
  require 'dotenv'
  Dotenv.load
end

# enable sessions for this project
enable :sessions




# ----------------------------------------------------------------------
#     How you handle your Alexa
# ----------------------------------------------------------------------

def update_status status, duration = nil

	# gets a corresponding message
  message = get_message_for status, duration
	# posts it to slack
  post_to_slack status, message

end

def get_message_for status, duration

	# Default response
  message = "other/unknown"

	# looks up a message based on the Status provided
  if status == "HERE"
    message = ENV['APP_USER'].to_s + " is in the office."
  elsif status == "BACK_IN"
    message = ENV['APP_USER'].to_s + " will be back in #{(duration/60).round} minutes"
  elsif status == "BE_RIGHT_BACK"
    message = ENV['APP_USER'].to_s + " will be right back"
  elsif status == "GONE_HOME"
    message = ENV['APP_USER'].to_s + " has left for the day. Check back tomorrow."
  elsif status == "DO_NOT_DISTURB"
    message = ENV['APP_USER'].to_s + " is busy. Please do not disturb."
  end

	# return the appropriate message
  message

end

def post_to_slack status_update, message

	# look up the Slack url from the env
  slack_webhook = ENV['SLACK_WEBHOOK']

	# create a formatted message
  formatted_message = "*Status Changed for #{ENV['APP_USER'].to_s} to: #{status_update}*\n"
  formatted_message += "#{message} "

	# Post it to Slack
  HTTParty.post slack_webhook, body: {text: formatted_message.to_s, username: "OutOfOfficeBot", channel: "back" }.to_json, headers: {'content-type' => 'application/json'}

end


class CustomHandler < AlexaSkillsRuby::Handler
  on_intent("HERE") do
  		# add a response to Alexa
      response.set_output_speech_text("I've updated your status to Here ")
  		# create a card response in the alexa app
      response.set_simple_card("Out of Office App", "Status is in the office.")
  		# log the output if needed
      logger.info 'Here processed'
  		# send a message to slack
      update_status "HERE"
  end
  on_intent("AMAZON.HelpIntent") do
    response.set_output_speech_text("You can ask me to tell you the current out of office status by saying current status. You can update your stats by saying tell out of office i'll be right back, i've gone home, i'm busy, i'm here or i'll be back in 10 minutes")
    logger.info 'HelpIntent processed'
  end
  on_intent("BACK_IN") do

   # Access the slots
   slots = request.intent.slots
   puts slots.to_s

   # Duration is returned in a particular format
   # Called ISO8601. Translate this into seconds
   duration = ISO8601::Duration.new( request.intent.slots["duration"] ).to_seconds

   # This will downsample the duration from a default seconds
   # To...
   if duration > 60 * 60 * 24
     days = duration/(60 * 60 * 24).round
     response.set_output_speech_text("I've set you away for #{ days } days")
   elsif duration > 60 * 60
     hours = duration/(60 * 60 ).round
     response.set_output_speech_text("I've set you away for #{ hours } hours")
   else
     mins = duration/(60).round
     response.set_output_speech_text("I've set you away for #{ mins } minutes")
   end
   logger.info 'BackIn processed'
   update_status "BACK_IN", duration
 end
end

  on_intent("About") do

    #response.set_output_speech("Welcome to Sinatra Sampler. I want to tell you a secret. I can't do very much")
    response.set_output_speech_ssml('<speak>Welcome to Sinatra Sampler. <audio src="soundbank://soundlibrary/human/amzn_sfx_clear_throat_ahem_01"/> I want to tell you a secret. <amazon:effect name="whispered">I can\'t do very much</amazon:effect> </speak>')
    logger.info 'GetAGIF processed'

  end



  on_intent("GetAGIF") do
    #response.set_output_speech('I sent a GIF to your phone! You should receive it really soon')
    response.set_output_speech_ssml('<speak>I sent a GIF to your phone! <break time="3s"/> You should receive it really soon</speak>')

    @client = Twilio::REST::Client.new ENV["TWILIO_ACCOUNT_SID"], ENV["TWILIO_AUTH_TOKEN"]

    gif_url = get_trending_gif

    @client.api.account.messages.create(
      from: ENV['TWILIO_FROM'],
      to: "+14803308165",
      body: "Here's a nice gif",
      media_url: gif_url
    )

    logger.info 'GetAGIF processed'
  end

  on_intent("GetWeather") do

    ForecastIO.api_key = ENV['DARK_SKY_WEATHER_API']
    forecast = ForecastIO.forecast(37.8267, -122.423)
    weather = get_weather_for 40.4406, 79.9959

    response_text = 'It is currently #{weather["currently"]["summary"]} with a temperature of #{weather["currently"]["temperature"]} degrees and a wind speed of #{weather["currently"]["windSpeed"]}.'
    response_text_ssml = '<speak><emphasis level="strong">It is currently #{weather["currently"]["summary"]}</emphasis> with a temperature of #{weather["currently"]["temperature"]} degrees and a wind speed of #{weather["currently"]["windSpeed"]}.</speak>'

    #response.set_output_speech( response_text )
    response.set_output_speech_ssml( response_text_ssml )
    logger.info 'GetWeather processed'
  end


  on_intent("GetAFact") do
    response.set_output_speech_text(  get_random_fact()  )
    logger.info 'GetFacts processed'
  end

  on_intent("GetJoke") do
    response.set_output_speech_text(  Giggle.random_joke   )
    logger.info 'GetJoke processed'
  end



  on_intent("AMAZON.HelpIntent") do
    #slots = request.intent.slots
    response.set_output_speech_text("You can ask me to send you a gif, get the weather, tell a joke or share a fact.")
    logger.info 'AMAZON.HelpIntent processed'
  end


end

# ----------------------------------------------------------------------
#     ROUTES, END POINTS AND ACTIONS
# ----------------------------------------------------------------------


get '/' do
  404
end


# THE APPLICATION ID CAN BE FOUND IN THE


post '/incoming/alexa' do
  content_type :json

  handler = CustomHandler.new(application_id: ENV['ALEXA_APPLICATION_ID'], logger: logger)

  begin
    hdrs = { 'Signature' => request.env['HTTP_SIGNATURE'], 'SignatureCertChainUrl' => request.env['HTTP_SIGNATURECERTCHAINURL'] }
    handler.handle(request.body.read, hdrs)
  rescue AlexaSkillsRuby::Error => e
    logger.error e.to_s
    403
  end

end



# ----------------------------------------------------------------------
#     ERRORS
# ----------------------------------------------------------------------



error 401 do
  "Not allowed!!!"
end




# ----------------------------------------------------------------------
#   METHODS
#   Add any custom methods below
# ----------------------------------------------------------------------

private


def get_random_fact

  ["Lassie was played by a group of male dogs; the main one was named Pal.",
    "Moon was Buzz Aldrin's (second man on the moon) mother's maiden name.",
    "Stewardesses is the longest word typed with only the left hand.",
    "Typewriter is the longest word that can be made using only the top row on the keyboard.",
    "$26 billion in ransom has been paid out in the U.S. in the past 20 years.",
    "$283,200 is the absolute highest amount of money you can win on Jeopardy.",
    "5,840 people with pillow related injuries checked into U.S. emergency rooms in 1992.",
    "7.5 million toothpicks can be created from a cord of wood.",
    "A 17th-century Swedish philologist claimed that in the Garden of Eden God spoke Swedish, Adam spoke Danish, and the serpent spoke French.",
    "A Boeing 747's wingspan is longer than the Wright brother's first flight.",
    "A Chinese checkerboard has 121 holes.",
    "A Macintosh LC575 has 182 speaker holes.",
    "A McDonald’s Big Mac bun has an average of 178 sesame seeds.",
    "A Rubik’s Cube can make 43,252,003,274,489,856,000 different combinations!",
    "A ball of glass will bounce higher than a ball of rubber. A ball of solid steel will bounce higher than one made entirely of glass.",
    "A bonnet is the cap on the fire hydrant.",
    "A cave man’s life span was only 18 years.",
    "A literal translation of a standard traffic sign in China: Give large space to the festive dog that makes sport in the roadway.",
    "A normal piece of paper cannot be folded more than 7 times.",
    "A poem written to celebrate a wedding is called a epithalamium.",
    "A short time before Lincoln's assassination, he dreamed he was going to die, and he related his dream to the Senate.",
    "A team of four people made angry birds in eight months.",
    "According to the National Health Foundation, after suffering a cold one should wait at least six days before kissing someone.",
    "Adolf Hitler was a vegetarian, and had only ONE testicle.",
    "Adolf Hitler's mother seriously considered having an abortion but was talked out of it by her doctor.",
    "Adolf Hitler’s favorite movie was King Kong.",
    "Adolph Hitler was Time Magazine’s Man of the Year for 1938.",
    "Airbags explode at 200 miles (322 km) per hour.",
    "Al Capone's business card said he was a used furniture dealer.",
    "Al Capone's famous scar (which earned him the nickname Scarface) was from an attack. The brother of a girl he had insulted attacked him with a knife, leaving him with the three distinctive scars.",
    "Al Capone’s business card said he was a used furniture dealer.",
    "Alaska could hold the 21 smallest States."
  ].sample


end



#--------------------------------------------------
#--------------------------------------------------
#--------------------------------------------------
#
# =>  WEATHER
#
#--------------------------------------------------
#--------------------------------------------------
#--------------------------------------------------


def get_weather_for lat, lon

  ForecastIO.api_key = ENV['DARK_SKY_WEATHER_API']

  forecast = ForecastIO.forecast(lat, lon)

  forecast
end


#--------------------------------------------------
#--------------------------------------------------
#--------------------------------------------------
#
# =>  GIPHY
#
#--------------------------------------------------
#--------------------------------------------------
#--------------------------------------------------


def get_gif_for query


  Giphy::Configuration.configure do |config|
    config.api_key = ENV["GIPHY_API_KEY"]
  end

  results = Giphy.search( query, {limit: 10})
  gif = nil

  #puts results.to_yaml
  unless results.empty?
    gif = results.sample.fixed_width_downsampled_image.url.to_s
  end

  gif

end


def get_trending_gif


  Giphy::Configuration.configure do |config|
    config.api_key = ENV["GIPHY_API_KEY"]
  end

  results = Giphy.trending(limit: 10)
  gif = nil

  #puts results.to_yaml
  unless results.empty?
    gif = results.sample.fixed_width_downsampled_image.url.to_s
  end

  gif

end
