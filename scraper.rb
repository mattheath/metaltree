require 'open-uri'
require 'nokogiri'

# Our base uri
uri = "http://www.gumtree.com/flatshare/london/page"

# Starting page
page = 1

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
    title = item.css("h3")
    link = item.css("a")[0]['href']

    puts "Title: #{title}"
    puts "Link: #{link}"
    puts ""
  end

  # increment page number
  page += 1

  # rate limit if we did have results before checking next page
  sleep 1 if items.length > 0

end

puts "No more results"
