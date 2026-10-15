package mxrb.sidecar;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Map;

import com.mendix.systemwideinterfaces.connectionbus.data.IDataColumnSchema;
import com.mendix.systemwideinterfaces.connectionbus.data.IDataRow;
import com.mendix.systemwideinterfaces.connectionbus.data.IDataTable;
import com.mendix.systemwideinterfaces.connectionbus.data.IDataTableSchema;
import com.mendix.systemwideinterfaces.core.IContext;

/** The rows the Ruby application's OQL engine returned for a query. */
public final class MxDataTable implements IDataTable {
	private final Schema schema = new Schema();
	private final List<Row> rows = new ArrayList<>();

	@SuppressWarnings("unchecked")
	public MxDataTable(Map<String, Object> table) {
		for (Object column : (List<Object>) table.get("columns")) {
			schema.columns.add(new Column(schema.columns.size(), (String) ((List<Object>) column).get(0)));
		}
		for (Object row : (List<Object>) table.get("rows")) {
			List<Object> values = new ArrayList<>();
			for (Object value : (List<Object>) row) {
				values.add(value instanceof MxObject object ? object.getId() : value);
			}
			rows.add(new Row(values));
		}
	}

	@Override
	public IDataTableSchema getSchema() {
		return schema;
	}

	@Override
	public int getRowCount() {
		return rows.size();
	}

	@Override
	public long getTotalRowCount() {
		return rows.size();
	}

	@Override
	public List<Row> getRows() {
		return new ArrayList<>(rows);
	}

	@Override
	@SuppressWarnings("unchecked")
	public Iterator<IDataRow> iterator() {
		return (Iterator<IDataRow>) (Iterator<?>) getRows().iterator();
	}

	private static final class Column implements IDataColumnSchema {
		private final int index;
		private final String name;

		Column(int index, String name) {
			this.index = index;
			this.name = name;
		}

		@Override
		public int getIndex() {
			return index;
		}

		@Override
		public String getName() {
			return name;
		}

		@Override
		public String toString() {
			return name;
		}
	}

	private static final class Schema implements IDataTableSchema {
		private final List<Column> columns = new ArrayList<>();

		@Override
		public boolean hasColumn(String name) {
			return getColumnIndex(name) >= 0;
		}

		@Override
		public int getColumnCount() {
			return columns.size();
		}

		@Override
		public int getColumnIndex(String name) {
			for (Column column : columns) {
				if (column.getName().equalsIgnoreCase(name)) {
					return column.getIndex();
				}
			}
			return -1;
		}

		@Override
		public IDataColumnSchema getColumnSchema(int index) {
			return columns.get(index);
		}

		@Override
		public IDataColumnSchema getColumnSchema(String name) {
			int index = getColumnIndex(name);
			return index < 0 ? null : columns.get(index);
		}

		@Override
		public List<IDataColumnSchema> getColumnSchemas() {
			return new ArrayList<>(columns);
		}
	}

	/** A row of the table. */
	public final class Row implements IDataRow {
		private final List<Object> values;

		Row(List<Object> values) {
			this.values = values;
		}

		@Override
		@SuppressWarnings("unchecked")
		public <T> T getValue(IContext context, int index) {
			return (T) values.get(index);
		}

		@Override
		public <T> T getValue(IContext context, String column) {
			int index = schema.getColumnIndex(column);
			if (index < 0) {
				throw new IllegalArgumentException("unknown column " + column);
			}
			return getValue(context, index);
		}

		@Override
		public <T> T getValue(IContext context, IDataColumnSchema column) {
			return getValue(context, column.getIndex());
		}

		@Override
		public boolean hasColumn(String column) {
			return schema.hasColumn(column);
		}

		@Override
		public int getColumnIndex(String column) {
			return schema.getColumnIndex(column);
		}

		@Override
		public IDataTableSchema getSchema() {
			return schema;
		}

		@Override
		public IDataTable getDataTable() {
			return MxDataTable.this;
		}
	}
}
