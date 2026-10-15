package mxrb.sidecar;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.mendix.systemwideinterfaces.connectionbus.requests.IParameterMap;
import com.mendix.systemwideinterfaces.connectionbus.requests.IRetrievalSchema;
import com.mendix.systemwideinterfaces.connectionbus.requests.types.IOQLTextGetRequest;

/** An OQL query, or a dataset by name, with its parameters and range. */
public final class MxOqlRequest implements IOQLTextGetRequest {
	private String query;
	private IParameterMap parameters = new Parameters();
	private IRetrievalSchema schema = new Range();

	public MxOqlRequest(String query) {
		this.query = query;
	}

	@Override
	public String getQuery() {
		return query;
	}

	@Override
	public void setQuery(String query) {
		this.query = query;
	}

	@Override
	public void setParameters(IParameterMap parameters) {
		this.parameters = parameters;
	}

	@Override
	public IParameterMap createParameterMap() {
		return new Parameters();
	}

	@Override
	public IParameterMap getParameters() {
		return parameters;
	}

	@Override
	public IRetrievalSchema getRetrievalSchema() {
		return schema;
	}

	@Override
	public void setRetrievalSchema(IRetrievalSchema schema) {
		this.schema = schema;
	}

	/** The parameter values by name, without the "$" the query writes. */
	public Map<String, Object> values() {
		return parameters instanceof Parameters own ? own.values : new LinkedHashMap<>();
	}

	/** Parameter values; an object stands for its identifier. */
	public static final class Parameters implements IParameterMap {
		private final Map<String, Object> values = new LinkedHashMap<>();

		@Override
		public void put(String name, Object value) {
			values.put(name.startsWith("$") ? name.substring(1) : name, value);
		}

		@Override
		public void putCollection(String name, List<?> collection) {
			put(name, collection);
		}
	}

	/** The rows to skip and the most to return; 0 or less returns all. */
	public static final class Range implements IRetrievalSchema {
		private long offset;
		private long amount = -1;

		@Override
		public long getOffset() {
			return offset;
		}

		@Override
		public void setOffset(long offset) {
			this.offset = offset;
		}

		@Override
		public long getAmount() {
			return amount;
		}

		@Override
		public void setAmount(long amount) {
			this.amount = amount;
		}
	}
}
