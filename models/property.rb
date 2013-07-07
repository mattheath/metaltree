class Property
  include Dynamoid::Document

  table :name => :properties, :key => :id

  field :title
  field :url
  field :provider
  field :provider_id

  field :description
  field :price
  field :cpm

  field :latitude
  field :longitude

  field :room_type
  field :property_type
  field :seller_type

  field :availability_date

  field :couples, :boolean
end
