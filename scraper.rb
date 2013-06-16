require 'toml'
require 'open-uri'
require 'nokogiri'
require 'aws'
require 'active_support/all'

# Load Config
path = File.join(File.dirname(__FILE__), 'config', 'config.toml')
CONFIG = TOML.load_file(path)

# Base uri we'll scrape
uri = CONFIG['uri']

# Starting page
page = 1

# SQS queue to use
queue_name = CONFIG['aws']['sqs']['queue_name']

# Get started with SQS in the EU
sqs_client = AWS::SQS.new(
  :access_key_id => CONFIG['aws']['access_key_id'],
  :secret_access_key => CONFIG['aws']['secret_access_key'],
  :sqs_endpoint => CONFIG['aws']['sqs']['endpoint']
)

# Ensure our queue exists
begin
  queue = sqs_client.queues.create(queue_name)
  puts "Queue Created: " + queue.url
rescue => err
  puts err.to_s
  exit
end

# Wait until the queue is available
retry_count = 0
try_again = true
while try_again
  queues = sqs_client.queues

  puts "Queues:"
  puts queues.map(&:url)

  # Does our queue exist yet?
  if queues.map(&:url).to_s =~ /\/#{queue_name}/
    retry_count = 0
    try_again = false
    puts "Queue Found"
  else
    try_again = true
    retry_count += 1
    sleep(1)
    puts("Queue not available yet - polling (" + retry_count.to_s + ")")
  end
end

# Start scraping!
results_found = true
while results_found do

  puts "loading page #{page}"
  doc = Nokogiri::HTML(open("#{uri}#{page}"))
  items = doc.css('#search-results > ul:not(.featured) li.hlisting')

  puts "Found #{items.length} results on page #{page}"

  # Abort if there are no more results
  results_found = false if items.length == 0

  # Run through results
  items.each do |item|

    id        = item.css("a.description")[0]['id'].scan(/\d+/).first
    title     = item.css("h3")[0].content.strip[0...100]
    link      = item.css("a")[0]['href'].strip
    created   = Time.strptime(item.css("span.dtlisted")[0]['title'].strip, '%Y%m%dT%H%M%S%z').utc
    timestamp = created.to_i

    # Build our message
    message = {
      "link"        => link,
      "provider"    => "gumtree",
      "provider_id" => id,
      "title"       => title,
      "created"     => timestamp
    }

    puts message.to_json

    # Send message
    status = queue.send_message message.to_json
    puts "Sent with id: #{status.message_id}"
    puts "" # vertical space, yo

  end

  exit

  # increment page number
  page += 1

  # rate limit if we did have results before checking next page
  sleep 1 if items.length > 0

end

puts "No more results"
