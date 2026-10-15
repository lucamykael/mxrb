package com.mendix.systemwideinterfaces.connectionbus.data;

import java.util.List;

/** The columns of an OQL result. */
public interface IDataTableSchema {
	boolean hasColumn(String name);
	int getColumnCount();
	int getColumnIndex(String name);
	IDataColumnSchema getColumnSchema(int index);
	IDataColumnSchema getColumnSchema(String name);
	List<? extends IDataColumnSchema> getColumnSchemas();
}
