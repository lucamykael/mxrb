package mxrb.sidecar;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.mendix.systemwideinterfaces.core.IDataType;

/**
 * The application's metamodel, as the Ruby application reports it: entities,
 * associations and microflows. It is read once, on the first use, because the
 * model does not change while the sidecar runs.
 */
public final class Metadata {
	private static volatile Metadata current;

	private final Map<String, MxMetaObject> objects = new LinkedHashMap<>();
	private final List<MxMetaAssociation> associations = new ArrayList<>();
	private final Map<String, Map<String, Object>> microflows = new LinkedHashMap<>();
	private final Map<String, MxMetaEnumeration> enumerations = new LinkedHashMap<>();

	@SuppressWarnings("unchecked")
	private Metadata(Map<String, Object> model) {
		for (Object entry : (List<Object>) model.get("objects")) {
			MxMetaObject object = new MxMetaObject(this, (Map<String, Object>) entry);
			objects.put(object.getName(), object);
		}
		for (Object entry : (List<Object>) model.get("associations")) {
			associations.add(new MxMetaAssociation(this, (Map<String, Object>) entry));
		}
		for (Object entry : (List<Object>) model.get("microflows")) {
			Map<String, Object> microflow = (Map<String, Object>) entry;
			microflows.put((String) microflow.get("name"), microflow);
		}
	}

	@SuppressWarnings("unchecked")
	public static Metadata get() {
		Metadata metadata = current;
		if (metadata == null) {
			synchronized (Metadata.class) {
				if (current == null) {
					current = new Metadata((Map<String, Object>) Bridge.current().call("metamodel"));
				}
				metadata = current;
			}
		}
		return metadata;
	}

	public MxMetaObject object(String name) {
		return objects.get(name);
	}

	public List<MxMetaObject> objects() {
		return new ArrayList<>(objects.values());
	}

	public List<MxMetaAssociation> associations() {
		return Collections.unmodifiableList(associations);
	}

	public MxMetaAssociation association(String name) {
		for (MxMetaAssociation association : associations) {
			if (association.getName().equals(name)) {
				return association;
			}
		}
		return null;
	}

	public List<String> microflowNames() {
		return new ArrayList<>(microflows.keySet());
	}

	/** A microflow's parameters by name, or null for an unknown microflow. */
	@SuppressWarnings("unchecked")
	public Map<String, IDataType> parameters(String microflow) {
		Map<String, Object> definition = microflows.get(microflow);
		if (definition == null) {
			return null;
		}
		Map<String, IDataType> parameters = new LinkedHashMap<>();
		for (Object entry : (List<Object>) definition.get("parameters")) {
			Map<String, Object> parameter = (Map<String, Object>) entry;
			parameters.put((String) parameter.get("name"), dataType((Map<String, Object>) parameter.get("datatype")));
		}
		return parameters;
	}

	@SuppressWarnings("unchecked")
	public IDataType returnType(String microflow) {
		Map<String, Object> definition = microflows.get(microflow);
		return definition == null ? null : dataType((Map<String, Object>) definition.get("return"));
	}

	public MxDataType dataType(Map<String, Object> datatype) {
		return new MxDataType(this, (String) datatype.get("type"), (String) datatype.get("dsl"),
				(String) datatype.get("object"), Boolean.TRUE.equals(datatype.get("list")));
	}

	/** An enumeration by name, with the values its attributes list. */
	@SuppressWarnings("unchecked")
	MxMetaEnumeration enumeration(String name, List<Object> values) {
		return enumerations.computeIfAbsent(name, key -> {
			List<String> identifiers = new ArrayList<>();
			for (Object value : values) {
				identifiers.add((String) ((Map<String, Object>) value).get("id"));
			}
			return new MxMetaEnumeration(key, identifiers);
		});
	}

	MxMetaEnumeration enumeration(String name) {
		return enumerations.get(name);
	}
}
