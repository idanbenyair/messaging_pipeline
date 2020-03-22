package me.skatz.kafka

import akka.actor.ActorSystem
import akka.kafka.javadsl.Consumer
import akka.kafka.{ConsumerSettings, Subscriptions}
import akka.stream.ActorMaterializer
import akka.stream.alpakka.cassandra.scaladsl.CassandraSink
import akka.stream.scaladsl.Flow
import com.datastax.driver.core.{BoundStatement, Cluster, PreparedStatement, Session}
import com.google.gson.Gson
import com.typesafe.config.{Config, ConfigFactory}
import me.skatz.database.Message
import me.skatz.utils.Configuration
import org.apache.kafka.clients.consumer.{ConsumerConfig, ConsumerRecord}
import org.apache.kafka.common.serialization.{ByteArrayDeserializer, StringDeserializer}
import spray.json.DefaultJsonProtocol

object CassandraProc extends App with DefaultJsonProtocol {
  implicit val system: ActorSystem = ActorSystem("CassandraProc")
  implicit val materializer: ActorMaterializer = ActorMaterializer()

  val config: Config = ConfigFactory.load.getConfig("akka.kafka.consumer")
  val consumerSettings: ConsumerSettings[Array[Byte], String] = ConsumerSettings(config, new ByteArrayDeserializer, new StringDeserializer)
    .withBootstrapServers(Configuration.bootstrapServer)
    .withGroupId(Configuration.groupId)
    .withProperty(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest")

  implicit val session: Session = Cluster.builder
    .addContactPoint(Configuration.cassandraUrl)
    .withPort(Configuration.cassandraPort.toInt)
    .build
    .connect()

  val kafkaSource = Consumer.plainSource(consumerSettings, Subscriptions.topics(Configuration.topicName))

  // flow to map kafka message which comes as JSON string to Message
  val toMessageFlow = Flow[ConsumerRecord[Array[Byte], String]].map(kafkaMessage => new Gson().fromJson(kafkaMessage.value(), classOf[Message]))

  val sink = {
    val statement = session.prepare(s"INSERT INTO ${Configuration.keyspace}.messages(msg_id, msg_data) VALUES (?, ?)")

    // we need statement binder to convert scala case class object types into java types
    val statementBinder: (Message, PreparedStatement) => BoundStatement = (msg, ps) =>
      ps.bind(msg.msg_id: Integer, msg.msg_data: String)

    // parallelism defines no of concurrent queries that can execute to cassandra
    CassandraSink[Message](parallelism = 2, statement = statement, statementBinder = statementBinder)
  }

  kafkaSource.via(toMessageFlow).runWith(sink, system)
}