package com.mendix.systemwideinterfaces.connectionbus.data;

import java.util.List;

/** The result of an OQL query. */
public interface IDataTable extends Iterable<IDataRow> {
	IDataTableSchema getSchema();
	int getRowCount();
	long getTotalRowCount();
	List<? extends IDataRow> getRows();
}
