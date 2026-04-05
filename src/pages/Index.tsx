const Index = () => {
  return (
    <div className="fixed inset-0 w-screen h-screen" style={{ paddingTop: 'env(safe-area-inset-top)' }}>
      <iframe
        src="https://birdz.sk"
        className="w-full h-full border-0"
        allow="notifications; camera; microphone; geolocation"
        title="Birdz.sk"
      />
    </div>
  );
};

export default Index;
