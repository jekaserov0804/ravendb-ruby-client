require "date"
require "ravendb"
require "spec_helper"

describe RavenDB::DocumentConventions do
  NOW = DateTime.now

  def setup
    @__test = RavenDatabaseTest.new(nil)
    @__test.setup

    store.open_session do |session|
      session.store(make_document("TestConversions/1"))
      session.store(make_document("TestConversions/2", NOW.next_day))
      session.save_changes
    end
  end

  def teardown
    @__test.teardown
  end

  def store
    @__test.store
  end

  def test_should_convert_on_load
    id = "TestConversions/1"

    store.open_session do |session|
      doc = session.load(id)
      check_doc(id, doc)
    end
  end

  def test_should_convert_on_store_then_reload
    id = "TestConversions/New"

    store.open_session do |session|
      session.store(make_document(id))
      session.save_changes
    end

    store.open_session do |session|
      doc = session.load(id)
      check_doc(id, doc)
    end
  end

  def test_should_convert_on_query
    store.open_session do |session|
      results = session.query(
        collection: "TestConversions"
      )
                       .where_greater_than("date", NOW)
                       .wait_for_non_stale_results
                       .all

      assert_equal(1, results.size)
      check_doc("TestConversions/2", results.first)
    end
  end

  def test_should_support_custom_id_property
    id = nil

    store.conventions.add_id_property_resolver do |document_info|
      if document_info[:document_type] == TestCustomDocumentId.name
        "item_id"
      end
    end

    store.open_session do |session|
      doc = TestCustomDocumentId.new(nil, "New Item")

      session.store(doc)
      session.save_changes
      id = doc.item_id
    end

    store.open_session do |session|
      doc = session.load(id)

      assert_equal(id, doc.item_id)
      assert_equal("New Item", doc.item_title)
    end
  end

  def test_should_support_custom_serializer
    id = nil

    store.conventions.add_id_property_resolver do |document_info|
      if document_info[:document_type] == TestCustomSerializer.name
        "item_id"
      end
    end

    store.conventions.add_attribute_serializer(CustomAttributeSerializer.new)

    store.open_session do |session|
      doc = TestCustomSerializer.new(nil, "New Item", [1, 2, 3])

      session.store(doc)
      session.save_changes
      id = doc.item_id
    end

    store.open_session do |session|
      doc = session.load(id)

      assert_equal(doc.item_id, id)
      assert_equal(doc.item_title, "New Item")
      assert_equal(doc.item_options, [1, 2, 3])

      raw_entities_and_metadata = session.instance_variable_get("@raw_entities_and_metadata")
      info = raw_entities_and_metadata[doc]
      raw_entity = info[:original_value]

      assert_equal("New Item", raw_entity["itemTitle"])
      assert_equal("1,2,3", raw_entity["itemOptions"])
    end
  end

  protected

  def make_document(id = nil, date = NOW)
    TestConversion.new(
      id, date, Foo.new("Foos/1", "Foo #1", 1), [
        Foo.new("Foos/2", "Foo #2", 2),
        Foo.new("Foos/3", "Foo #3", 3)
      ])
  end

  def check_foo(foo, id_of_foo = 1)
    assert(foo.is_a?(Foo))
    assert_equal("Foos/#{id_of_foo}", foo.id)
    assert_equal("Foo ##{id_of_foo}", foo.name)
    assert_equal(id_of_foo, foo.order)
  end

  def check_doc(id, doc)
    assert(doc.is_a?(TestConversion))
    assert_equal(id, doc.id)
    assert(doc.date.is_a?(DateTime))
    assert(doc.foos.is_a?(Array))

    check_foo(doc.foo)
    doc.foos.each_index { |index| check_foo(doc.foos[index], index + 2) }
  end
end
