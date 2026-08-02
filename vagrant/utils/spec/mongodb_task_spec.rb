require 'rake'

load File.expand_path('../tasks/mongodb.rake', __dir__)

RSpec.describe MongoDBTask do
  before do
    described_class.instance_variable_set(:@mongo_client, nil)
  end

  describe '.drop_all' do
    it 'drops every configured test database' do
      database = instance_double(Mongo::Database)
      selected_client = instance_double(Mongo::Client, database:)
      client = instance_double(Mongo::Client)

      expect(Mongo::Client).to receive(:new)
        .with(['127.0.0.1:27017'], database: 'admin')
        .and_return(client)
      allow(client).to receive(:use).and_return(selected_client)
      allow(database).to receive(:drop)

      described_class.drop_all

      expect(client).to have_received(:use).with('backup_test_01').once
      expect(client).to have_received(:use).with('backup_test_02').once
      expect(database).to have_received(:drop).twice
    end
  end

  describe '.create_all' do
    it 'inserts the configured records through the current driver API' do
      collection = instance_double(Mongo::Collection)
      database = instance_double(Mongo::Database)
      selected_client = instance_double(Mongo::Client, database:)
      client = instance_double(Mongo::Client)

      allow(Mongo::Client).to receive(:new).and_return(client)
      allow(client).to receive(:use).and_return(selected_client)
      allow(database).to receive(:[]).and_return(collection)
      allow(collection).to receive(:insert_one)

      described_class.create_all

      expect(client).to have_received(:use).with('backup_test_01').once
      expect(client).to have_received(:use).with('backup_test_02').once
      expect(database).to have_received(:[]).with('ones').twice
      expect(database).to have_received(:[]).with('twos').twice
      expect(database).to have_received(:[]).with('threes').twice
      expect(collection).to have_received(:insert_one).with(number: 0).exactly(6).times
      expect(collection).to have_received(:insert_one).with(number: 424).once
      expect(collection).to have_received(:insert_one).exactly(1_475).times
    end
  end
end
