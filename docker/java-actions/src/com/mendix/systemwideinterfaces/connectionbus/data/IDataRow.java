package com.mendix.systemwideinterfaces.connectionbus.data;

import com.mendix.systemwideinterfaces.core.IContext;

/** A row of an OQL result; an ID column holds an IMendixIdentifier. */
public interface IDataRow {
	<T> T getValue(IContext context, String column);
	<T> T getValue(IContext context, int index);
	<T> T getValue(IContext context, IDataColumnSchema column);
	boolean hasColumn(String column);
	int getColumnIndex(String column);
	IDataTableSchema getSchema();
	IDataTable getDataTable();
}
